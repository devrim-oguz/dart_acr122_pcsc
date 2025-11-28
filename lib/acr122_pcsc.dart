library acr122_pcsc;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:tuple/tuple.dart';
import 'package:event/event.dart';
import 'package:pcsc_wrapper/pcsc_wrapper.dart';

import 'src/reader_constants.dart';

class CardDetailsACR122 extends EventArgs {
  final List<int> cardNUID;
  CardDetailsACR122(this.cardNUID);
}

class CardReaderACR122 {
  //Card Events////////////////////////////////////////////////////////////////////////////////////
  final cardDetectedEvent = Event<CardDetailsACR122>();
  final cardRemovedEvent = Event();

  //Class Destructor///////////////////////////////////////////////////////////////////////////////
  void dispose() async {
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
  static Future<List<String>> listReaders() async {
    //Establish a temporary context to list the readers
    final pcscLib = PCSCWrapper();
    final SCardContext context = await pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);

    //Get the list of readers
    final readerList = await pcscLib.listReaders(context.hContext);

    //Release the temporary context
    await pcscLib.releaseContext(context);

    //Return the reader list
    return readerList;
  }

  Future<bool> initReader( String readerName ) async {
    //Try to establish a pcsc context
    final SCardContext libraryContext = await _pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    if( libraryContext.hContext == 0 ) return false;

    //Copy the reader name and context
    _libraryContext = libraryContext;
    _readerName = readerName;

    //Start the card detection task but do not wait for it to complete
    _cardDetectionTask(readerName);

    return true;
  }

  Future<bool> loadKey(List<int> inputKey) async {
    if( _currentCard == null ) return false;
    final List<int> command = _encodeCommand(ReaderConstants.loadKeyCommand, 0, 0, inputKey, 0);
    final response = await _transmitCommand(_currentCard!, command);
    return response.item1;
  }

  Future<bool> generalAuthenticate(int blockNumber) async {
    if( _currentCard == null ) return false;
    final List<int> command = _encodeCommand(ReaderConstants.generalAuthCommand, 0, 0, [0x01, 0x00, blockNumber, 0x60, 0x00], 0);
    final response = await _transmitCommand(_currentCard!, command);
    return response.item1;

    /*
    Data Array Meaning:
      0x01: Indicates the version of the structure (should be 0x01).
      0x00: Indicates the key structure (should be 0x00 for key type A).
      blockNumber: Indicates the block number for which the key is loaded.
      0x60: Indicates the key type (0x60 for key type A, 0x61 for key type B).
      0x00: Indicates the key number in the reader's volatile memory (0x00 for key number 0).
    */
  }

  Future<Tuple2<bool, List<int>>> readBinary(int blockNumber) async {
    if( _currentCard == null ) return Tuple2(false, []);
    final List<int> command = _encodeCommand(ReaderConstants.readBinaryCommand, 0, blockNumber, [], 16);
    return await _transmitCommand(_currentCard!, command);
  }

  Future<bool> updateBinary(int blockNumber, List<int> data) async {
    if( _currentCard == null ) return false;
    final List<int> command = _encodeCommand(ReaderConstants.updateBinaryCommand, 0, blockNumber, data, 0);
    final result = await _transmitCommand(_currentCard!, command);
    return result.item1;
  }

  //Card Detection/////////////////////////////////////////////////////////////////////////////////
  static bool _checkFlag(int bitField, int flagPosition) {
    return (bitField & flagPosition) == flagPosition;
  }

  Future<void> _cardDetectionTask(String readerName) async {
    //Create a PCSC instance and establish context
    final SCardContext libraryContext = await _detectionPcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);

    //Keep track of the known state
    int knownState = PcscConstants.SCARD_STATE_UNAWARE;
    bool cardPresent = false;

    //Card detection loop
    while(!_isDisposed) {
      try {
        //Wait for the reader state to change
        final readerState = SCardReaderState(readerName, knownState, PcscConstants.SCARD_STATE_UNAWARE, List.empty());
        final outputStates = await _detectionPcscLib.getStatusChange(libraryContext.hContext, PcscConstants.SCARD_INFINITE, [readerState]);

        //Get the current state
        final currentState = outputStates[0].dwEventState;
        
        //Check if the state has changed
        if( currentState == knownState ) {
          //Wait for 50ms before checking again
          await Future.delayed(Duration(milliseconds: 50));
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
        //Print the error
        stdout.write("Error on card detection -> ");
        stdout.writeln(err);

        //Wait for a while before trying again
        await Future.delayed(Duration(milliseconds: 1000));
      }
    }

    //Release the detection context
    await _detectionPcscLib.releaseContext(libraryContext);
  }

  //Command Encoding-Decoding//////////////////////////////////////////////////////////////////////
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

  static Tuple2<bool, List<int>> _decodeResponse(List<int> response) {
    //Check if the response is valid
    if (response.length < 2) {
      return const Tuple2(false, []);
    }
    
    //Copy the command result and data
    final List<int> commandResult = response.sublist(response.length - 2);
    final List<int> commandData = response.sublist(0, (response.length - 2));

    //Check if the command was successful
    final bool success = ListEquality<int>().equals(commandResult, ReaderConstants.successResponse);

    //Return the result
    return Tuple2(success, commandData);
  }

  Future<Tuple2<bool, List<int>>> _transmitCommand(SCardHandle selectedCard, List<int> command) async {
    final hCard = selectedCard.hCard;
    final activeProtocol = selectedCard.dwActiveProtocol;

    return _decodeResponse(await _pcscLib.transmit(hCard, activeProtocol, command));
  }

  //Utility Methods////////////////////////////////////////////////////////////////////////////////
  Future<Tuple2<bool, List<int>>> _readCardNUID(SCardHandle selectedCard) async {
    //Create the read NUID command and transmit it
    final List<int> command = _encodeCommand(ReaderConstants.readIdentifierCommand, 0, 0, [], 4);
    final response = await _transmitCommand(selectedCard, command);

    //Parse the response
    final isSuccess = response.item1;
    final resultData = response.item2;

    //Check if the response is valid
    if( !isSuccess || !(resultData.length >= 4) ) return Tuple2(false, []);

    //Copy the card NUID
    final List<int> cardNUID = resultData.sublist(resultData.length - 4);

    //Return the card NUID
    return Tuple2(isSuccess, cardNUID);
  }

  Future<bool> _tryConnectingCard() async {
    if( _libraryContext == null || _readerName == null ) {
      throw Exception('Reader not initialized');
    }

    _currentCard = await _pcscLib.connect(_libraryContext!.hContext, _readerName!, PcscConstants.SCARD_SHARE_SHARED, PcscConstants.SCARD_PROTOCOL_ANY);
    return _currentCard != null;
  }

  Future<void> _disconnectCard() async {
    if( _currentCard == null ) return;
    await _pcscLib.disconnect(_currentCard!.hCard, PcscConstants.SCARD_LEAVE_CARD);
    _currentCard = null;
  }

  //Detection Handlers/////////////////////////////////////////////////////////////////////////////
  Future<void> _cardDetectionHandler() async {
    try {
      //Try to connect to the card
      if( await _tryConnectingCard() != true ) {
        await _disconnectCard();
        stdout.writeln("Failed to connect to the card");
        return;
      }

      //Try reading the card identifier
      final cardIdentifier = await _readCardNUID(_currentCard!);
      final identifierReadSuccess = cardIdentifier.item1;
      final identifierData = cardIdentifier.item2;

      if( !identifierReadSuccess ) {
        await _disconnectCard();
        stdout.writeln("Failed to read the card identifier");
        return;
      }

      //Check if the card identifier is valid
      cardDetectedEvent.broadcast(CardDetailsACR122(identifierData));
    }
    catch(err) {
      stdout.write("Error while connecting to the card: ");
      stdout.writeln(err);
    }
  }

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
}