import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_mlkit_converter/image_mlkit_converter.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

import 'text_pagination.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  // the Google ML Kit text recognizer
  late TextRecognizer _textRecognizer;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;
  bool _processing = false;
  RecognizedText? _recognizedText;
  final List<String> _recognizedTextList = [];
  final TextPagination _pagination = TextPagination();

  final Stopwatch _stopwatch = Stopwatch();

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });

    // initialize the TextRecognizer
    _textRecognizer = TextRecognizer();
  }

  @override
  void dispose() async {
    // clean up the TextRecognizer resources
    await _textRecognizer.close();

    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // text recognition improves with a higher quality image
    qualityIndex = 2;

    // kick off the connection to Frame and start the app if possible
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> onRun() async {
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: '3-Tap: take photo\n______________\n1-Tap: next page\n2-Tap: previous page'
      )
    );
  }

  @override
  Future<void> onCancel() async {
    _recognizedText = null;
    _recognizedTextList.clear();
    _pagination.clear();
  }

  @override
  Future<void> onTap(int taps) async {
    switch (taps) {
      case 1:
        // next
        _pagination.nextPage();
        frame!.sendMessage(
          TxPlainText(
            msgCode: 0x0a,
            text: _pagination.getCurrentPage().join('\n')
          )
        );
        break;
      case 2:
        // prev
        _pagination.previousPage();
        frame!.sendMessage(
          TxPlainText(
            msgCode: 0x0a,
            text: _pagination.getCurrentPage().join('\n')
          )
        );
        break;
      case 3:
        // check if there's processing in progress already and drop the request if so
        if (!_processing) {
          _processing = true;
          // start new vision capture
          // asynchronously kick off the capture/processing pipeline
          capture().then(process);
        }
        break;
      default:
    }
  }

  /// The vision pipeline to run when a photo is captured
  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;
    _recognizedTextList.clear();

    try {
      // update Widget UI
      // For the widget we rotate it upon display with a transform, not changing the source image
      Image im = Image.memory(imageData, gaplessPlayback: true,);

      setState(() {
        _image = im;
        _imageMeta = meta;
      });

      // Perform vision processing pipeline on the current image
      try {
        // will sometimes throw an Exception on decoding, but doesn't return null
        _stopwatch.reset();
        _stopwatch.start();
        img.Image im = img.decodeJpg(imageData)!;
        _stopwatch.stop();
        _log.fine(() => 'Jpeg decoding took: ${_stopwatch.elapsedMilliseconds} ms');

        // Android mlkit needs NV21 InputImage format
        // iOS mlkit needs bgra8888 InputImage format
        // In both cases orientation metadata is passed to mlkit, so no need to bake in a rotation
        _stopwatch.reset();
        _stopwatch.start();
        // Frame images are rotated 90 degrees clockwise
        InputImage mlkitImage = ImageMlkitConverter.imageToMlkitInputImage(im, InputImageRotation.rotation90deg);
        _stopwatch.stop();
        _log.fine(() => 'NV21/BGRA8888 conversion took: ${_stopwatch.elapsedMilliseconds} ms');

        // run the text recognizer
        _stopwatch.reset();
        _stopwatch.start();
        _recognizedText = await _textRecognizer.processImage(mlkitImage);
        _stopwatch.stop();
        _log.fine(() => 'Text recognition took: ${_stopwatch.elapsedMilliseconds} ms');

        // display to Frame if text has been recognized
        if (_recognizedText!.blocks.isNotEmpty) {

          _pagination.clear();

          // (reverse) sort the text blocks, that seem to come back kind of bottom to top but not really
          var sortedTextBlocks = _recognizedText!.blocks..sort((a, b) => b.boundingBox.top.compareTo(a.boundingBox.top));

          // loop over any text found
          for (TextBlock block in sortedTextBlocks) {
            // (reverse) sort the text lines within the block by y-coordinate too
            var sortedTextLines = block.lines..sort((a, b) => b.boundingBox.top.compareTo(a.boundingBox.top));
            var sortedTextStrings = sortedTextLines.map((result) => result.text).toList();

            // then add the text from this block
            _pagination.appendLine(sortedTextStrings.join('\n'));
          }

          _log.fine(() => 'Text found: $_pagination');

          // print the detected barcodes on the Frame display
          await frame!.sendMessage(
            TxPlainText(
              msgCode: 0x0a,
              text: _pagination.getCurrentPage().join('\n')
            )
          );
        }

      } catch (e) {
        _log.severe('Error converting bytes to image: $e');
      }

      // indicate that we're done processing
      _processing = false;

    } catch (e) {
      _log.severe('Error processing photo: $e');
      // TODO rethrow;?
    }
  }


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Vision Text Recognition',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Vision Text Recognition'),
          actions: [getBatteryWidget()]
        ),
        drawer: getCameraDrawer(),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  Transform(
                    alignment: Alignment.center,
                    // images are rotated 90 degrees clockwise from the Frame
                    // so reverse that for display
                    transform: Matrix4.rotationZ(-pi*0.5),
                    child: _image,
                  ),
                  const Divider(),
                  if (_imageMeta != null) _imageMeta!,
                ],
              )
            ),
            const Divider(),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
