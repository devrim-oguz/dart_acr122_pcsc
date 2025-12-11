import 'package:pcsc_wrapper/pcsc_wrapper.dart';

class ReadBinaryResult {
  final SCardResult result;
  final List<int> data;

  bool get isSuccess => result.isSuccess && _commandSuccess;
  final bool _commandSuccess;

  String get errorMessage {
    if (!result.isSuccess) return result.message;
    if (!_commandSuccess) return 'Card command failed';
    return 'Success';
  }

  ReadBinaryResult(this.result, this._commandSuccess, this.data);
  ReadBinaryResult.failure(this.result) : _commandSuccess = false, data = [];
}

class ReadNUIDResult {
  final SCardResult result;
  final List<int> nuid;

  bool get isSuccess => result.isSuccess && _commandSuccess;
  final bool _commandSuccess;

  String get errorMessage {
    if (!result.isSuccess) return result.message;
    if (!_commandSuccess) return 'Card command failed';
    return 'Success';
  }

  ReadNUIDResult(this.result, this._commandSuccess, this.nuid);
  ReadNUIDResult.failure(this.result) : _commandSuccess = false, nuid = [];
}

class CommandResult {
  final SCardResult result;
  final List<int> data;

  bool get isSuccess => result.isSuccess && commandSuccess;
  final bool commandSuccess;

  String get errorMessage {
    if (!result.isSuccess) return result.message;
    if (!commandSuccess) return 'Card command failed';
    return 'Success';
  }

  CommandResult(this.result, this.commandSuccess, this.data);
  CommandResult.failure(this.result) : commandSuccess = false, data = [];
}
