library acr122_pcsc;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:event/event.dart';
import 'package:pcsc_wrapper/pcsc_wrapper.dart' hide PcscResult;

import 'common/reader_constants.dart';
import 'common/reader_types.dart';

export 'common/reader_types.dart';

//Event Arguments////////////////////////////////////////////////////////////////////////////////
class CardDetailsACR122 extends EventArgs {
  final List<int> cardNUID;
  CardDetailsACR122(this.cardNUID);
}

class CardReaderACR122 {
  //Card Events////////////////////////////////////////////////////////////////////////////////////
  final cardDetectedEvent = Event<CardDetailsACR122>();
  final cardRemovedEvent = Event();

  //Class Destructor///////////////////////////////////////////////////////////////////////////////
  Future<void> dispose() async {
    //Stop the detection task
    _isDisposed = true;

    //Close the reader context
    if( _libraryContext != null ) {
      await _pcscLib.releaseContext(_libraryContext!);
      _libraryContext = null;
    }

    _readerName = null;
    _currentCard = null;
  }

  //Public Methods/////////////////////////////////////////////////////////////////////////////////
  /// Lists all available card readers in the system
  static Future<ListReadersResult> listReaders() async {
    //Establish a temporary context to list the readers
    final pcscLib = PCSCWrapper();
    final establishResult = await pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    
    if( !establishResult.result.isSuccess ) {
      return ListReadersResult(PcscResult.fromSCard(establishResult.result), []);
    }

    //Get the list of readers
    final listResult = await pcscLib.listReaders(establishResult.value.hContext);

    //Release the temporary context
    await pcscLib.releaseContext(establishResult.value);

    //Return the reader list result
    return ListReadersResult(PcscResult.fromSCard(listResult.result), listResult.value);
  }

  /// Initializes the card reader with the specified name and optional read delay
  Future<PcscResult> initReader( String readerName, { Duration? readDelay = null } ) async {
    //Try to establish a pcsc context
    final establishResult = await _pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    if( !establishResult.result.isSuccess ) return PcscResult.fromSCard(establishResult.result);

    //Copy the reader name and context
    _libraryContext = establishResult.value;
    _readerName = readerName;

    //Set the read delay if provided
    _cardReadDelay = readDelay;

    //Start the card detection task but do not wait for it to complete
    _cardDetectionTask(readerName);

    return PcscResult.fromSCard(establishResult.result);
  }

  /// Loads a 6-byte authentication key into the reader's volatile memory
  Future<BinaryCommandResult> loadKey(List<int> inputKey) async {
    if( _currentCard == null ) {
      return BinaryCommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }

    final List<int> command = _encodeCommand(ReaderConstants.loadKeyCommand, 0, 0, inputKey, 0);
    return await _transmitCommand(_currentCard!, command);
  }

  /// Authenticates access to a specific block using the previously loaded key
  Future<BinaryCommandResult> generalAuthenticate(int blockNumber) async {
    if( _currentCard == null ) {
      return BinaryCommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }

    final List<int> command = _encodeCommand(ReaderConstants.generalAuthCommand, 0, 0, [0x01, 0x00, blockNumber, 0x60, 0x00], 0);
    return await _transmitCommand(_currentCard!, command);

    /*
    Data Array Meaning:
      0x01: Indicates the version of the structure (should be 0x01).
      0x00: Indicates the key structure (should be 0x00 for key type A).
      blockNumber: Indicates the block number for which the key is loaded.
      0x60: Indicates the key type (0x60 for key type A, 0x61 for key type B).
      0x00: Indicates the key number in the reader's volatile memory (0x00 for key number 0).
    */
  }

  /// Reads 16 bytes of data from the specified block number
  Future<ReadBinaryResult> readBinary(int blockNumber) async {
    if( _currentCard == null ) {
      return ReadBinaryResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }

    final List<int> command = _encodeCommand(ReaderConstants.readBinaryCommand, 0, blockNumber, [], 16);
    final commandResult = await _transmitCommand(_currentCard!, command);
    return ReadBinaryResult.fromStatus(commandResult.status, commandResult.cardCommandSuccess, commandResult.data);
  }

  /// Writes data to the specified block number (data must be 16 bytes)
  Future<BinaryCommandResult> updateBinary(int blockNumber, List<int> data) async {
    if( _currentCard == null ) {
      return BinaryCommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }

    final List<int> command = _encodeCommand(ReaderConstants.updateBinaryCommand, 0, blockNumber, data, 0);
    return await _transmitCommand(_currentCard!, command);
  }

  //Card Detection/////////////////////////////////////////////////////////////////////////////////
  /// Checks if a specific flag is set in the bit field
  static bool _checkFlag(int bitField, int flagPosition) {
    return (bitField & flagPosition) == flagPosition;
  }

  /// Background task that continuously monitors for card insertion and removal
  Future<void> _cardDetectionTask(String readerName) async {
    //Create a PCSC instance and establish context
    final establishResult = await _detectionPcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    if( !establishResult.result.isSuccess ) {
      stdout.writeln("Failed to establish detection context: ${establishResult.result.message}");
      return;
    }
    final libraryContext = establishResult.value;

    //Keep track of the known state
    int knownState = PcscConstants.SCARD_STATE_UNAWARE;
    bool cardPresent = false;

    //Card detection loop
    while(!_isDisposed) {
      try {
        //Wait for the reader state to change (1 second timeout)
        final readerState = SCardReaderState(readerName, knownState, PcscConstants.SCARD_STATE_UNAWARE, List.empty());
        final statusChangeResult = await _detectionPcscLib.getStatusChange(libraryContext.hContext, 1000, [readerState]);

        //Check for timeout - continue loop to check _isDisposed
        if( statusChangeResult.result.code == PcscConstants.SCARD_E_TIMEOUT ) {
          continue;
        }

        //Check for other non-success results
        if( !statusChangeResult.result.isSuccess ) {
          stdout.writeln("Status change error: ${statusChangeResult.result.message}");
          await Future.delayed(Duration(milliseconds: 1000));
          continue;
        }

        //Get the current state
        final currentState = statusChangeResult.value[0].dwEventState;
        
        //Check if the state has changed
        if( currentState == knownState ) {
          continue;
        }

        //Update the known state
        knownState = currentState;

        //Check for card detection or removal
        if( _checkFlag(knownState, PcscConstants.SCARD_STATE_PRESENT) ) {
          if( cardPresent == false ) {
            _cardDetectionHandler();
            cardPresent = true;
          }
        }
        else if( _checkFlag(knownState, PcscConstants.SCARD_STATE_EMPTY) ) {
          if( cardPresent == true ) {
            _cardRemovedHandler();
            cardPresent = false;
          }
        }
      }
      catch(err) {
        stdout.write("Error on card detection -> ");
        stdout.writeln(err);
        await Future.delayed(Duration(milliseconds: 1000));
      }
    }

    //Release the detection context
    await _detectionPcscLib.releaseContext(libraryContext);
  }

  //Command Encoding-Decoding//////////////////////////////////////////////////////////////////////
  /// Encodes an APDU command with parameters, data, and expected response length
  static List<int> _encodeCommand(List<int> commandBytes, int paramOne, int paramTwo, List<int> data, int expectedLength) {
    List<int> result = [...commandBytes, paramOne, paramTwo];

    if (data.isNotEmpty) {
      result.add(data.length);
      result.addAll(data);
    }

    if (expectedLength > 0) {
      result.add(expectedLength);
    }

    return result;
  }

  /// Decodes the card response and separates status bytes from data
  static BinaryCommandResult _decodeResponse(SCardResult scardResult, List<int> response) {
    //Check if the response is valid
    if (response.length < 2) {
      return BinaryCommandResult.fromSCard(scardResult, false, []);
    }
    
    //Copy the command result and data
    final List<int> commandResult = response.sublist(response.length - 2);
    final List<int> commandData = response.sublist(0, (response.length - 2));

    //Check if the command was successful
    final bool success = ListEquality<int>().equals(commandResult, ReaderConstants.successResponse);

    //Return the result
    return BinaryCommandResult.fromSCard(scardResult, success, commandData);
  }

  /// Transmits a command to the card and returns the decoded response
  Future<BinaryCommandResult> _transmitCommand(SCardHandle selectedCard, List<int> command) async {
    final hCard = selectedCard.hCard;
    final activeProtocol = selectedCard.dwActiveProtocol;

    final transmitResult = await _pcscLib.transmit(hCard, activeProtocol, command);
    if( !transmitResult.result.isSuccess ) {
      return BinaryCommandResult.failure(transmitResult.result);
    }

    return _decodeResponse(transmitResult.result, transmitResult.value);
  }

  //Utility Methods////////////////////////////////////////////////////////////////////////////////
  /// Reads the 4-byte NUID (Non-Unique ID) from the card
  Future<ReadNuidResult> _readCardNUID(SCardHandle selectedCard) async {
    //Create the read NUID command and transmit it
    final List<int> command = _encodeCommand(ReaderConstants.readIdentifierCommand, 0, 0, [], 4);
    final commandResult = await _transmitCommand(selectedCard, command);

    //Check if the response is valid
    if( !commandResult.isSuccess || commandResult.data.length < 4 ) {
      return ReadNuidResult.failure(commandResult.status);
    }

    //Copy the card NUID
    final List<int> cardNUID = commandResult.data.sublist(commandResult.data.length - 4);

    //Return the card NUID
    return ReadNuidResult.fromStatus(commandResult.status, cardNUID);
  }

  /// Attempts to establish a connection with the card in the reader
  Future<bool> _tryConnectingCard() async {
    if( _libraryContext == null || _readerName == null ) {
      stdout.writeln('Reader not initialized');
      return false;
    }

    final connectResult = await _pcscLib.connect(_libraryContext!.hContext, _readerName!, PcscConstants.SCARD_SHARE_SHARED, PcscConstants.SCARD_PROTOCOL_ANY);
    if( !connectResult.result.isSuccess ) {
      stdout.writeln("Connect failed: ${connectResult.result.message}");
      return false;
    }

    _currentCard = connectResult.value;
    return true;
  }

  /// Disconnects from the currently connected card
  Future<void> _disconnectCard() async {
    if( _currentCard == null ) return;
    final disconnectResult = await _pcscLib.disconnect(_currentCard!.hCard, PcscConstants.SCARD_LEAVE_CARD);
    if( !disconnectResult.isSuccess ) {
      stdout.writeln("Disconnect warning: ${disconnectResult.message}");
    }
    _currentCard = null;
  }

  //Detection Handlers/////////////////////////////////////////////////////////////////////////////
  /// Handles card detection by connecting to the card and reading its NUID
  Future<void> _cardDetectionHandler() async {
    try {
      //Wait for a short delay to allow the card to stabilize
      if(_cardReadDelay != null ) await Future.delayed(_cardReadDelay!);

      //Try to connect to the card
      if( await _tryConnectingCard() != true ) {
        await _disconnectCard();
        stdout.writeln("Failed to connect to the card");
        return;
      }

      //Try reading the card identifier
      final cardIdentifier = await _readCardNUID(_currentCard!);

      if( !cardIdentifier.isSuccess ) {
        await _disconnectCard();
        stdout.writeln("Failed to read the card identifier");
        return;
      }

      //Check if the card identifier is valid
      cardDetectedEvent.broadcast(CardDetailsACR122(cardIdentifier.nuid));
    }
    catch(err) {
      stdout.write("Error while connecting to the card: ");
      stdout.writeln(err);
    }
  }

  /// Handles card removal by disconnecting and broadcasting the removal event
  Future<void> _cardRemovedHandler() async {
    try {
      await _disconnectCard();
      cardRemovedEvent.broadcast();
    }
    catch(err) {
      stdout.write("Error while disconnecting from the card: ");
      stdout.writeln(err);
    }

  }

  //Private Variables//////////////////////////////////////////////////////////////////////////////
  //PCSC Library Instances
  final PCSCWrapper _pcscLib = PCSCWrapper();
  final PCSCWrapper _detectionPcscLib = PCSCWrapper();

  //Reader State Variables
  SCardContext? _libraryContext;
  String? _readerName;
  SCardHandle? _currentCard;
  bool _isDisposed = false;
  Duration? _cardReadDelay = null;
}