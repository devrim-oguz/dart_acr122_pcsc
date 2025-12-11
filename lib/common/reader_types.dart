import 'package:pcsc_wrapper/pcsc_wrapper.dart';

// Wrapper result types with new names
class PcscResult {
  final int code;
  final String message;
  final bool isSuccess;
  
  PcscResult._(this.code, this.message, this.isSuccess);
  
  factory PcscResult.fromSCard(SCardResult scardResult) {
    return PcscResult._(
      scardResult.code,
      scardResult.message,
      scardResult.isSuccess,
    );
  }
  
  factory PcscResult.fromCode(int code) {
    final scardResult = SCardResult(code);
    return PcscResult.fromSCard(scardResult);
  }
}

class ReaderListResult {
  final PcscResult status;
  final List<String> readers;
  
  ReaderListResult(this.status, this.readers);
  
  ReaderListResult.fromInternal(ListReadersResult internal) 
      : status = PcscResult.fromSCard(internal.result),
        readers = internal.readers;
  
  bool get isSuccess => status.isSuccess;
}

// Reader-specific result types
class BinaryCommandResult {
  final PcscResult status;
  final bool cardCommandSuccess;
  final List<int> data;

  BinaryCommandResult._(this.status, this.cardCommandSuccess, this.data);

  factory BinaryCommandResult.fromSCard(SCardResult scardResult, bool cardCommandSuccess, List<int> data) {
    return BinaryCommandResult._(
      PcscResult.fromSCard(scardResult),
      cardCommandSuccess,
      data,
    );
  }

  factory BinaryCommandResult.failure(SCardResult scardResult) {
    return BinaryCommandResult._(
      PcscResult.fromSCard(scardResult),
      false,
      [],
    );
  }

  bool get isSuccess => status.isSuccess && cardCommandSuccess;
}

class ReadBinaryResult {
  final PcscResult status;
  final bool cardCommandSuccess;
  final List<int> data;

  ReadBinaryResult._(this.status, this.cardCommandSuccess, this.data);

  factory ReadBinaryResult.fromStatus(PcscResult status, bool cardCommandSuccess, List<int> data) {
    return ReadBinaryResult._(status, cardCommandSuccess, data);
  }

  factory ReadBinaryResult.failure(SCardResult scardResult) {
    return ReadBinaryResult._(
      PcscResult.fromSCard(scardResult),
      false,
      [],
    );
  }

  bool get isSuccess => status.isSuccess && cardCommandSuccess;
}

class ReadNuidResult {
  final PcscResult status;
  final List<int> nuid;

  ReadNuidResult._(this.status, this.nuid);

  factory ReadNuidResult.fromStatus(PcscResult status, List<int> nuid) {
    return ReadNuidResult._(status, nuid);
  }

  factory ReadNuidResult.failure(PcscResult status) {
    return ReadNuidResult._(status, []);
  }

  bool get isSuccess => status.isSuccess && nuid.isNotEmpty;
}
