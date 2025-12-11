import 'dart:io';

import 'package:acr122_pcsc/acr122_pcsc.dart';
import 'package:event/event.dart';

// ============================================================================
// CONFIGURATION - Modify these values as needed
// ============================================================================

/// Target block number for read/write operations
const int TARGET_BLOCK = 2;

/// Default MIFARE Classic authentication key (factory default: all 0xFF)
const List<int> AUTHENTICATION_KEY = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

/// Sample data to write to the target block (16 bytes for MIFARE Classic)
const List<int> SAMPLE_DATA = [
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
];

// ============================================================================
// DEMO CLASS
// ============================================================================

class CardOperationsDemo {
  static CardReaderACR122? reader;
  static bool operationInProgress = false;
}

// ============================================================================
// EVENT HANDLERS
// ============================================================================

void cardDetectedHandler(CardDetailsACR122? cardDetails) async {
  if (CardOperationsDemo.operationInProgress) return;
  CardOperationsDemo.operationInProgress = true;
  
  stdout.writeln('\n=== Card Detected ===');
  stdout.writeln('Card NUID: ${_formatHexData(cardDetails!.cardNUID)}');
  
  // Give time for card to stabilize
  await Future.delayed(Duration(milliseconds: 500));
  
  try {
    await performCardOperations();
  } catch (e) {
    stdout.writeln('❌ Error during card operations: $e');
  }
  
  CardOperationsDemo.operationInProgress = false;
}

void cardRemovedHandler(EventArgs? args) async {
  stdout.writeln('\n=== Card Removed ===');
  CardOperationsDemo.operationInProgress = false;
}

// ============================================================================
// MAIN PROGRAM
// ============================================================================

void main() async {
  stdout.writeln('🔧 ACR122 PCSC Library - Block Read/Write Demo');
  stdout.writeln('===========================================');
  
  final reader = CardReaderACR122();
  CardOperationsDemo.reader = reader;
  
  try {
    // List available readers
    stdout.writeln('\n📡 Discovering NFC readers...');
    final readerListResult = await CardReaderACR122.listReaders();
    
    if (!readerListResult.result.isSuccess) {
      stdout.writeln('❌ Failed to list readers: ${readerListResult.result.message}');
      return;
    }
    
    if (readerListResult.readers.isEmpty) {
      stdout.writeln('❌ No NFC readers found. Please connect an ACR122 reader.');
      return;
    }
    
    stdout.writeln('📋 Available readers:');
    for (int i = 0; i < readerListResult.readers.length; i++) {
      stdout.writeln('   ${i + 1}. ${readerListResult.readers[i]}');
    }
    
    // Initialize the first reader
    stdout.writeln('\n🔌 Initializing reader: ${readerListResult.readers[0]}');
    final initResult = await reader.initReader(readerListResult.readers[0]);
    if (!initResult.isSuccess) {
      stdout.writeln('❌ Failed to initialize reader: ${initResult.message}');
      return;
    }
    stdout.writeln('✅ Reader initialized successfully');
    
    // Subscribe to card events
    reader.cardDetectedEvent.subscribe(cardDetectedHandler);
    reader.cardRemovedEvent.subscribe(cardRemovedHandler);
    
    stdout.writeln('\n🎯 Ready! Place a MIFARE Classic card on the reader...');
    stdout.writeln('📋 Demo will:');
    stdout.writeln('   • Authenticate with block $TARGET_BLOCK using default key');
    stdout.writeln('   • Read current data from block $TARGET_BLOCK');  
    stdout.writeln('   • Write sample data to block $TARGET_BLOCK');
    stdout.writeln('   • Verify the written data');
    stdout.writeln('   • Restore original data');
    stdout.writeln('\n⚠️  Note: This demo uses block $TARGET_BLOCK and default MIFARE Classic keys.');
    stdout.writeln('   Ensure your card uses default keys or modify the configuration at the top of the file.');
    
    // Keep the program running
    while (true) {
      await Future.delayed(Duration(seconds: 1));
    }
    
  } catch (err) {
    stdout.writeln('❌ Error during initialization: $err');
  } finally {
    // Cleanup
    reader.dispose();
  }
}

// ============================================================================
// CARD OPERATIONS
// ============================================================================

Future<void> performCardOperations() async {
  final reader = CardOperationsDemo.reader!;
  
  stdout.writeln('\n--- Starting Card Operations ---');
  stdout.writeln('Target Block: $TARGET_BLOCK');
  
  // Step 1: Load the authentication key
  stdout.writeln('1. Loading authentication key...');
  final loadKeyResult = await reader.loadKey(AUTHENTICATION_KEY);
  if (!loadKeyResult.isSuccess) {
    stdout.writeln('   ❌ Failed to load authentication key: ${loadKeyResult.errorMessage}');
    return;
  }
  stdout.writeln('   ✅ Authentication key loaded successfully');
  
  // Step 2: Authenticate with target block
  stdout.writeln('2. Authenticating with block $TARGET_BLOCK...');
  final authResult = await reader.generalAuthenticate(TARGET_BLOCK);
  if (!authResult.isSuccess) {
    stdout.writeln('   ❌ Failed to authenticate with block $TARGET_BLOCK: ${authResult.errorMessage}');
    return;
  }
  stdout.writeln('   ✅ Authentication successful');
  
  // Step 3: Read current data from target block
  stdout.writeln('3. Reading current data from block $TARGET_BLOCK...');
  final readResult = await reader.readBinary(TARGET_BLOCK);
  if (!readResult.isSuccess) {
    stdout.writeln('   ❌ Failed to read block $TARGET_BLOCK: ${readResult.errorMessage}');
    return;
  }
  
  final originalData = readResult.data;
  stdout.writeln('   📖 Original data: ${_formatHexData(originalData)}');
  
  // Step 4: Write new data to target block
  stdout.writeln('4. Writing new data to block $TARGET_BLOCK...');
  stdout.writeln('   📝 Writing data: ${_formatHexData(SAMPLE_DATA)}');
  
  final writeResult = await reader.updateBinary(TARGET_BLOCK, SAMPLE_DATA);
  if (!writeResult.isSuccess) {
    stdout.writeln('   ❌ Failed to write to block $TARGET_BLOCK: ${writeResult.errorMessage}');
    return;
  }
  stdout.writeln('   ✅ Data written successfully');
  
  // Step 5: Read back the written data to verify
  stdout.writeln('5. Verifying written data...');
  final verifyResult = await reader.readBinary(TARGET_BLOCK);
  if (!verifyResult.isSuccess) {
    stdout.writeln('   ❌ Failed to verify written data: ${verifyResult.errorMessage}');
    return;
  }
  
  final writtenData = verifyResult.data;
  stdout.writeln('   📖 Written data: ${_formatHexData(writtenData)}');
  
  // Check if data matches
  bool dataMatches = _compareDataArrays(writtenData, SAMPLE_DATA);
  
  if (dataMatches) {
    stdout.writeln('   ✅ Data verification successful - write operation confirmed');
  } else {
    stdout.writeln('   ⚠️  Data verification failed - written data does not match expected data');
  }
  
  // Step 6: Restore original data (optional)
  stdout.writeln('6. Restoring original data...');
  final restoreResult = await reader.updateBinary(TARGET_BLOCK, originalData);
  if (restoreResult.isSuccess) {
    stdout.writeln('   ✅ Original data restored');
  } else {
    stdout.writeln('   ⚠️  Failed to restore original data: ${restoreResult.errorMessage}');
  }
  
  stdout.writeln('\n--- Card Operations Complete ---');
}


// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Formats a list of bytes as a readable hex string
String _formatHexData(List<int> data) {
  return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase();
}

/// Compares two byte arrays for equality
bool _compareDataArrays(List<int> array1, List<int> array2) {
  if (array1.length != array2.length) return false;
  
  for (int i = 0; i < array1.length; i++) {
    if (array1[i] != array2[i]) return false;
  }
  
  return true;
}