class ReaderConstants {
  //APDU Commands
  static final List<int> readIdentifierCommand = [0xFF, 0xCA];
  static final List<int> loadKeyCommand = [0xFF, 0x82];
  static final List<int> generalAuthCommand = [0xFF, 0x86];
  static final List<int> readBinaryCommand = [0xFF, 0xB0];
  static final List<int> updateBinaryCommand = [0xFF, 0xD6];
  static final List<int> directCommunicationCommand = [0xFF, 0x00];

  //APDU Responses
  static final List<int> successResponse = [0x90, 0x00];
}