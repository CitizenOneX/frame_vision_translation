import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_mlkit_converter/image_mlkit_converter.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/rx/photo.dart';
import 'package:simple_frame_app/rx/tap.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/tx/camera_settings.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/code.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // the Google ML Kit text recognizer
  late TextRecognizer _textRecognizer;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;
  RecognizedText? _recognizedText;

  final Stopwatch _stopwatch = Stopwatch();

  // camera settings
  int _qualityIndex = 0;
  final List<double> _qualityValues = [10, 25, 50, 100];
  int _meteringIndex = 2;
  final List<String> _meteringValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  int _autoExpGainTimes = 2; // val >= 0; number of times auto exposure and gain algorithm will be run every 100ms
  double _exposure = 0.18; // 0.0 <= val <= 1.0
  double _exposureSpeed = 0.5;  // 0.0 <= val <= 1.0
  int _shutterLimit = 16383; // 4 < val < 16383
  int _analogGainLimit = 1;     // 0 (1?) <= val <= 248
  double _whiteBalanceSpeed = 0.5;  // 0.0 <= val <= 1.0

  // tap subscription
  StreamSubscription<int>? _tapSubs;

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });

    _textRecognizer = TextRecognizer();
  }

  @override
  void initState() {
    super.initState();

    // kick off the connection to Frame and start the app if possible
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> run() async {
    setState(() {
      currentState = ApplicationState.running;
    });

    // listen for taps for next(1)/prev(2) content and "new vision capture" (3)
    _tapSubs?.cancel();
    _tapSubs = RxTap().attach(frame!.dataResponse)
      .listen((taps) async {
        _log.fine(() => 'taps: $taps');
        switch (taps) {
          case 1:
            // next
            break;
          case 2:
            // prev
            break;
          case 3:
            // start new vision capture
            await runCaptureAndProcess();
            break;
          default:
        }
      }
    );

    // let Frame know to subscribe for taps and send them to us
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 1));

    // prompt the user to begin tapping
    await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: '3-Tap: new photo\n____________\n1-Tap: next\n2-Tap: previous'));

    // run() completes but we stay in ApplicationState.running because the tap listener is active
  }

  /// The vision pipeline to run when triple-tapped
  Future<void> runCaptureAndProcess() async {
    // Some apps might start a while (state==running) loop here that needs to be canceled to finish
    // but here we will just request one photo and do our processing

    try {
      // the image metadata (camera settings) to show under the image
      ImageMetadata meta = ImageMetadata(_qualityValues[_qualityIndex].toInt(), _autoExpGainTimes, _meteringValues[_meteringIndex], _exposure, _exposureSpeed, _shutterLimit, _analogGainLimit, _whiteBalanceSpeed);

      // send the lua command to request a photo from the Frame
      _stopwatch.reset();
      _stopwatch.start();
      await frame!.sendMessage(TxCameraSettings(
        msgCode: 0x0d,
        qualityIndex: _qualityIndex,
        autoExpGainTimes: _autoExpGainTimes,
        meteringIndex: _meteringIndex,
        exposure: _exposure,
        exposureSpeed: _exposureSpeed,
        shutterLimit: _shutterLimit,
        analogGainLimit: _analogGainLimit,
        whiteBalanceSpeed: _whiteBalanceSpeed,
      ));

      // synchronously await the image response
      Uint8List imageData = await RxPhoto(qualityLevel: _qualityValues[_qualityIndex].toInt()).attach(frame!.dataResponse).first;

      // received a whole-image Uint8List with jpeg header and footer included
      _stopwatch.stop();

      try {
        // update Widget UI
        Image im = Image.memory(imageData, gaplessPlayback: true,);

        // add the size and elapsed time to the image metadata widget
        meta.size = imageData.length;
        meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;

        _log.fine(() => 'Image file size in bytes: ${imageData.length}, elapsedMs: ${_stopwatch.elapsedMilliseconds}');

        setState(() {
          _image = im;
          _imageMeta = meta;
        });

        // Perform vision processing pipeline
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

            // TODO pagination requires an instance variable, tracking displayed lines etc.
            List<String> frameText = [];
            // loop over any text found
            for (TextBlock block in _recognizedText!.blocks) {
              frameText.add('${block.recognizedLanguages}: ${block.text}');
            }

            _log.fine(() => 'Text found: $frameText');

            // print the detected barcodes on the Frame display
            await frame!.sendMessage(
              TxPlainText(
                msgCode: 0x0a,
                text: TextUtils.wrapText(frameText.join('\n'), 640, 4).join('\n')
              )
            );
          }

        } catch (e) {
          _log.severe('Error converting bytes to image: $e');
        }

      } catch (e) {
        _log.severe('Error converting bytes to image: $e');
        setState(() {
          currentState = ApplicationState.ready;
        });

      }

    } catch (e) {
      _log.severe('Error executing application: $e');
      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });

    // let Frame know to stop sending taps
    await frame!.sendMessage(TxCode(msgCode: 0x10, value: 0));

    // clear the display
    await frame!.sendMessage(TxPlainText(msgCode: 0x0a, text: ' '));

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Vision',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Vision'),
          actions: [getBatteryWidget()]
        ),
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const DrawerHeader(
                decoration: BoxDecoration(
                  color: Colors.blue,
                ),
                child: Text('Camera Settings',
                  style: TextStyle(color: Colors.white, fontSize: 24),
                  ),
              ),
              ListTile(
                title: const Text('Quality'),
                subtitle: Slider(
                  value: _qualityIndex.toDouble(),
                  min: 0,
                  max: _qualityValues.length - 1,
                  divisions: _qualityValues.length - 1,
                  label: _qualityValues[_qualityIndex].toString(),
                  onChanged: (value) {
                    setState(() {
                      _qualityIndex = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Auto Exposure/Gain Runs'),
                subtitle: Slider(
                  value: _autoExpGainTimes.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: _autoExpGainTimes.toInt().toString(),
                  onChanged: (value) {
                    setState(() {
                      _autoExpGainTimes = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Metering'),
                subtitle: DropdownButton<int>(
                  value: _meteringIndex,
                  onChanged: (int? newValue) {
                    setState(() {
                      _meteringIndex = newValue!;
                    });
                  },
                  items: _meteringValues
                      .map<DropdownMenuItem<int>>((String value) {
                    return DropdownMenuItem<int>(
                      value: _meteringValues.indexOf(value),
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ),
              ListTile(
                title: const Text('Exposure'),
                subtitle: Slider(
                  value: _exposure,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _exposure.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposure = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Exposure Speed'),
                subtitle: Slider(
                  value: _exposureSpeed,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _exposureSpeed.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposureSpeed = value;
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Shutter Limit'),
                subtitle: Slider(
                  value: _shutterLimit.toDouble(),
                  min: 4,
                  max: 16383,
                  divisions: 10,
                  label: _shutterLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _shutterLimit = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('Analog Gain Limit'),
                subtitle: Slider(
                  value: _analogGainLimit.toDouble(),
                  min: 0,
                  max: 248,
                  divisions: 8,
                  label: _analogGainLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _analogGainLimit = value.toInt();
                    });
                  },
                ),
              ),
              ListTile(
                title: const Text('White Balance Speed'),
                subtitle: Slider(
                  value: _whiteBalanceSpeed,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: _whiteBalanceSpeed.toString(),
                  onChanged: (value) {
                    setState(() {
                      _whiteBalanceSpeed = value;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
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

class ImageMetadata extends StatelessWidget {
  final int quality;
  final int exposureRuns;
  final String metering;
  final double exposure;
  final double exposureSpeed;
  final int shutterLimit;
  final int analogGainLimit;
  final double whiteBalanceSpeed;

  ImageMetadata(this.quality, this.exposureRuns, this.metering, this.exposure, this.exposureSpeed, this.shutterLimit, this.analogGainLimit, this.whiteBalanceSpeed, {super.key});

  late int size;
  late int elapsedTimeMs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Quality: $quality\nExposureRuns: $exposureRuns\nMetering: $metering\nExposure: $exposure'),
        const Spacer(),
        Text('ExposureSpeed: $exposureSpeed\nShutterLim: $shutterLimit\nAnalogGainLim: $analogGainLimit\nWBSpeed: $whiteBalanceSpeed'),
        const Spacer(),
        Text('Size: ${(size/1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms'),
      ],
    );
  }
}