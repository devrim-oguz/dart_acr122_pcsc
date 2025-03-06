import 'dart:io';

import 'package:acr122_pcsc/acr122_pcsc.dart';
import 'package:event/event.dart';

class Common {
  static int readCount = 0;
}

void cardDetectedHandler( CardDetailsACR122? cardDetails ) async {
  stdout.writeln('Card Detected! NUID: ${cardDetails!.cardNUID}, Read Count: ${Common.readCount}');
  Common.readCount++;
}

void cardRemovedHandler( EventArgs? args ) async {
  stdout.writeln('Card Removed!');
}

void main() async {
  final reader = CardReaderACR122();
  final readerList = await reader.listReaders();

  try{
    await reader.initReader(readerList[0]);
  } 
  catch(err) {
    print("Error while initializing the reader: $err");
  }

  reader.cardDetectedEvent.subscribe(cardDetectedHandler);
  reader.cardRemovedEvent.subscribe(cardRemovedHandler);

  //Wait for events
  while(true) {
    await Future.delayed(Duration(seconds: 1));
  }
}
