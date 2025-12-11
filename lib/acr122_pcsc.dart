library acr122_pcsc;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:event/event.dart';
import 'package:pcsc_wrapper/pcsc_wrapper.dart';

import 'src/reader_constants.dart';
import 'src/acr122_types.dart';

export 'src/acr122_types.dart';

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
  static Future<ListReadersResult> listReaders() async {
    //Establish a temporary context to list the readers
    final pcscLib = PCSCWrapper();
    final establishResult = await pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    
    if( !establishResult.result.isSuccess ) {
      return ListReadersResult(establishResult.result, []);
    }

    //Get the list of readers
    final listResult = await pcscLib.listReaders(establishResult.context.hContext);

    //Release the temporary context
    await pcscLib.releaseContext(establishResult.context);

    //Return the reader list result
    return listResult;
  }

  Future<SCardResult> initReader( String readerName, { Duration? readDelay = null } ) async {
    //Try to establish a pcsc context
    final establishResult = await _pcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    if( !establishResult.result.isSuccess ) return establishResult.result;

    //Copy the reader name and context
    _libraryContext = establishResult.context;
    _readerName = readerName;

    //Set the read delay if provided
    _cardReadDelay = readDelay;

    //Start the card detection task but do not wait for it to complete
    _cardDetectionTask(readerName);

    return establishResult.result;
  }

  Future<CommandResult> loadKey(List<int> inputKey) async {
    if( _currentCard == null ) {
      return CommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }
    final List<int> command = _encodeCommand(ReaderConstants.loadKeyCommand, 0, 0, inputKey, 0);
    return await _transmitCommand(_currentCard!, command);
  }

  Future<CommandResult> generalAuthenticate(int blockNumber) async {
    if( _currentCard == null ) {
      return CommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
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

  Future<ReadBinaryResult> readBinary(int blockNumber) async {
    if( _currentCard == null ) {
      return ReadBinaryResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }
    final List<int> command = _encodeCommand(ReaderConstants.readBinaryCommand, 0, blockNumber, [], 16);
    final result = await _transmitCommand(_currentCard!, command);
    return ReadBinaryResult(result.result, result.commandSuccess, result.data);
  }

  Future<CommandResult> updateBinary(int blockNumber, List<int> data) async {
    if( _currentCard == null ) {
      return CommandResult.failure(SCardResult(PcscConstants.SCARD_E_NO_SMARTCARD));
    }
    final List<int> command = _encodeCommand(ReaderConstants.updateBinaryCommand, 0, blockNumber, data, 0);
    return await _transmitCommand(_currentCard!, command);
  }

  //Card Detection/////////////////////////////////////////////////////////////////////////////////
  static bool _checkFlag(int bitField, int flagPosition) {
    return (bitField & flagPosition) == flagPosition;
  }

  Future<void> _cardDetectionTask(String readerName) async {
    //Create a PCSC instance and establish context
    final establishResult = await _detectionPcscLib.establishContext(PcscConstants.CARD_SCOPE_SYSTEM);
    if( !establishResult.result.isSuccess ) {
      stdout.writeln("Failed to establish detection context: ${establishResult.result.message}");
      return;
    }
    final libraryContext = establishResult.context;

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
        final currentState = statusChangeResult.readerStates[0].dwEventState;
        
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

  static CommandResult _decodeResponse(SCardResult scardResult, List<int> response) {
    //Check if the response is valid
    if (response.length < 2) {
      return CommandResult(scardResult, false, []);
    }
    
    //Copy the command result and data
    final List<int> commandResult = response.sublist(response.length - 2);
    final List<int> commandData = response.sublist(0, (response.length - 2));

    //Check if the command was successful
    final bool success = ListEquality<int>().equals(commandResult, ReaderConstants.successResponse);

    //Return the result
    return CommandResult(scardResult, success, commandData);
  }

  Future<CommandResult> _transmitCommand(SCardHandle selectedCard, List<int> command) async {
    final hCard = selectedCard.hCard;
    final activeProtocol = selectedCard.dwActiveProtocol;

    final transmitResult = await _pcscLib.transmit(hCard, activeProtocol, command);
    if( !transmitResult.result.isSuccess ) {
      return CommandResult.failure(transmitResult.result);
    }

    return _decodeResponse(transmitResult.result, transmitResult.response);
  }

  //Utility Methods////////////////////////////////////////////////////////////////////////////////
  Future<ReadNUIDResult> _readCardNUID(SCardHandle selectedCard) async {
    //Create the read NUID command and transmit it
    final List<int> command = _encodeCommand(ReaderConstants.readIdentifierCommand, 0, 0, [], 4);
    final response = await _transmitCommand(selectedCard, command);

    //Check if the response is valid
    if( !response.isSuccess || response.data.length < 4 ) {
      return ReadNUIDResult(response.result, false, []);
    }

    //Copy the card NUID
    final List<int> cardNUID = response.data.sublist(response.data.length - 4);

    //Return the card NUID
    return ReadNUIDResult(response.result, true, cardNUID);
  }

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

    _currentCard = connectResult.handle;
    return true;
  }

  Future<void> _disconnectCard() async {
    if( _currentCard == null ) return;
    final disconnectResult = await _pcscLib.disconnect(_currentCard!.hCard, PcscConstants.SCARD_LEAVE_CARD);
    if( !disconnectResult.isSuccess ) {
      stdout.writeln("Disconnect warning: ${disconnectResult.message}");
    }
    _currentCard = null;
  }

  //Detection Handlers/////////////////////////////////////////////////////////////////////////////
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


/*
New Return Types:

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pcsc_wrapper/common/pcsc_constants.dart';

//Function Return Types
class SCardResult {
  final int code;
  String get message => PcscConstants.returnCodeToString(code);
  bool get isSuccess => code == PcscConstants.SCARD_S_SUCCESS;

  SCardResult(this.code);
}

class EstablishContextResult {
  final SCardResult result;
  final SCardContext context;

  EstablishContextResult(this.result, this.context);
}

class ConnectResult {
  final SCardResult result;
  final SCardHandle handle;

  ConnectResult(this.result, this.handle);
}

class ReconnectResult {
  final SCardResult result;
  final SCardHandle handle;

  ReconnectResult(this.result, this.handle);
}

class StatusResult {
  final SCardResult result;
  final SCardStatus status;

  StatusResult(this.result, this.status);
}

class GetStatusChangeResult {
  final SCardResult result;
  final List<SCardReaderState> readerStates;

  GetStatusChangeResult(this.result, this.readerStates);
}

class ControlResult {
  final SCardResult result;
  final List<int> response;

  ControlResult(this.result, this.response);
}

class TransmitResult {
  final SCardResult result;
  final List<int> response;

  TransmitResult(this.result, this.response);
}

class ListReaderGroupsResult {
  final SCardResult result;
  final List<String> groups;

  ListReaderGroupsResult(this.result, this.groups);
}

class ListReadersResult {
  final SCardResult result;
  final List<String> readers;

  ListReadersResult(this.result, this.readers);
}

class GetAttribResult {
  final SCardResult result;
  final List<int> attrib;

  GetAttribResult(this.result, this.attrib);
}

//Library Specific Types
class SCardContext {
  final int hContext;
  SCardContext(this.hContext);
}

class SCardHandle {
  final int hCard;
  final int dwActiveProtocol;

  SCardHandle(this.hCard, this.dwActiveProtocol);
}

class SCardStatus {
  final String szReaderName;
  final int dwState;
  final int dwProtocol;
  final List<int> bAtr;

  SCardStatus(this.szReaderName, this.dwState, this.dwProtocol, this.bAtr);
}

class SCardReaderState {
  final String szReader;
  final int dwCurrentState;
  final int dwEventState;
  final List<int> rgbAtr;

  SCardReaderState(this.szReader, this.dwCurrentState, this.dwEventState, this.rgbAtr);
}

class SCardReaderResponse {
  final List<Uint8> bytes;

  SCardReaderResponse(this.bytes);
}


*/


/*
Function definitions:

library pcsc_wrapper;

import 'dart:io';

import 'package:pcsc_wrapper/common/pcsc_bindings_base.dart';
import 'package:pcsc_wrapper/bindings/linux_bindings.dart';
import 'package:pcsc_wrapper/common/pcsc_types.dart';

export 'common/pcsc_types.dart';
export 'common/pcsc_constants.dart';

class PCSCWrapper {
  late PcscBindings _bindings;

  PCSCWrapper() {
    if (Platform.isLinux) {
      _bindings = LinuxBindings();
    }
    /*else if (Platform.isMacOS) {
      _bindings = MacOSBindings();
    }
    else if (Platform.isWindows) {
      _bindings = WindowsBindings();
    }*/
    else {
      throw Exception("Unsupported operating system");
    }
  }

  void dispose() => _bindings.dispose();

  Future<EstablishContextResult> establishContext(int scope) =>
      _bindings.establishContext(scope);

  Future<SCardResult> releaseContext(SCardContext context) =>
      _bindings.releaseContext(context.hContext);

  Future<SCardResult> isValidContext(int hContext) =>
      _bindings.isValidContext(hContext);

  Future<ListReadersResult> listReaders(int hContext) =>
      _bindings.listReaders(hContext);

  Future<ConnectResult> connect(int hContext, String szReader, int dwShareMode, int dwPreferredProtocols) =>
      _bindings.connect(hContext, szReader, dwShareMode, dwPreferredProtocols);

  Future<ReconnectResult> reconnect(int hCard, int dwShareMode, int dwPreferredProtocols, int dwInitialization) =>
      _bindings.reconnect(hCard, dwShareMode, dwPreferredProtocols, dwInitialization);

  Future<SCardResult> disconnect(int hCard, int dwDisposition) =>
      _bindings.disconnect(hCard, dwDisposition);

  Future<SCardResult> beginTransaction(int hCard) =>
      _bindings.beginTransaction(hCard);

  Future<SCardResult> endTransaction(int hCard, int dwDisposition) =>
      _bindings.endTransaction(hCard, dwDisposition);

  Future<StatusResult> status(int hCard) =>
      _bindings.status(hCard);

  Future<GetStatusChangeResult> getStatusChange(int hContext, int dwTimeout, List<SCardReaderState> rgReaderStates) =>
      _bindings.getStatusChange(hContext, dwTimeout, rgReaderStates);

  Future<ControlResult> control(int hCard, int dwControlCode, List<int> pbSendBuffer) =>
      _bindings.control(hCard, dwControlCode, pbSendBuffer);

  Future<TransmitResult> transmit(int hCard, int pioSendPci, List<int> pbSendBuffer) =>
      _bindings.transmit(hCard, pioSendPci, pbSendBuffer);

  Future<ListReaderGroupsResult> listReaderGroups(int hContext) =>
      _bindings.listReaderGroups(hContext);

  Future<SCardResult> cancel(int hContext) =>
      _bindings.cancel(hContext);

  Future<GetAttribResult> getAttrib(int hCard, int dwAttrId) =>
      _bindings.getAttrib(hCard, dwAttrId);

  Future<SCardResult> setAttrib(int hCard, int dwAttrId, List<int> pbAttr) =>
      _bindings.setAttrib(hCard, dwAttrId, pbAttr);
}

*/
