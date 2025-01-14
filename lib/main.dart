import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:image/image.dart' as img;
import 'package:image_mlkit_converter/image_mlkit_converter.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
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
  // the Google ML Kit text recognizer and translator
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.japanese);
  final _translator = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.japanese,
    targetLanguage: TranslateLanguage.english);

  // the image and metadata to show
  Image? _image;
  Uint8List? _uprightImageBytes;
  ImageMetadata? _imageMeta;
  bool _processing = false;
  RecognizedText? _recognizedText;
  final List<String> _recognizedTextList = [];
  final List<String> _translatedTextList = [];
  final TextPagination _pagination = TextPagination();

  final Stopwatch _stopwatch = Stopwatch();

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  void dispose() async {
    // clean up the ML Kit resources
    await _textRecognizer.close();
    await _translator.close();

    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // text recognition improves with a higher quality image
    qualityIndex = 4;

    // set default resolution to be the largest possible for text recognition tasks
    resolution = 720;

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
    _translatedTextList.clear();

    try {
      _uprightImageBytes = imageData;

      // update Widget UI
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
        // Frame images are rotated 90 degrees clockwise usually
        // but we got FrameVisionApp to pre-rotate them back since we're rotating them for sharing anyway
        InputImage mlkitImage = ImageMlkitConverter.imageToMlkitInputImage(im, InputImageRotation.rotation0deg);
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

          // loop over any text found and translate block by block
          for (TextBlock block in sortedTextBlocks) {
            // (reverse) sort the text lines within the block by y-coordinate too
            var sortedTextLines = block.lines..sort((a, b) => b.boundingBox.top.compareTo(a.boundingBox.top));
            var sortedTextStrings = sortedTextLines.map((result) => result.text).toList();

            // then add the text from this block
            var fullBlockText = sortedTextStrings.join('\n');
            var translatedBlock = await _translator.translateText(fullBlockText);

            _recognizedTextList.add(fullBlockText);
            _translatedTextList.add(translatedBlock);
            _pagination.appendLine(translatedBlock);
          }

          _log.fine(() => 'Text found: $_recognizedTextList, $_translatedTextList');
          setState(() {});

          // print the detected text on the Frame display
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
      String err = 'Error processing photo: $e';
      _log.fine(err);
      setState(() {
        _recognizedTextList.add(err);
      });
      _processing = false;
      // TODO rethrow;?
    }
  }

  /// Use the platform Share mechanism to share the image and the generated text
  static void _shareImage(Uint8List? jpegBytes, String text) async {
    if (jpegBytes != null) {
      try {
        // Share the image bytes as a JPEG file
        await Share.shareXFiles(
          [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
          text: text,
        );
      }
      catch (e) {
        _log.severe('Error preparing image for sharing: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Vision Translation',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Vision Translation'),
          actions: [getBatteryWidget()]
        ),
        drawer: getCameraDrawer(),
        body: Column(
          children: [
            Expanded(
            child: GestureDetector(
              onTap: () {
                if (_uprightImageBytes != null) {
                  _shareImage(_uprightImageBytes, '${_recognizedTextList.join('\n')}\n${_translatedTextList.join('\n')}');
                }
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _image,
                    ),
                  ),
                  if (_imageMeta != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          ImageMetadataWidget(meta: _imageMeta!),
                          const Divider()
                        ]),
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                          ),
                          child: Text(_translatedTextList[index]),
                        );
                      },
                      childCount: _translatedTextList.length,
                    ),
                  ),
                  // This ensures the list can grow dynamically
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Container(), // Empty container to allow scrolling
                  ),
                ],
              ),
            ),
          ),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
