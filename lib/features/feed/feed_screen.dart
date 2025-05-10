import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';

class FeedScreen extends StatefulWidget {
  final FrameService frameService;

  const FeedScreen({super.key, required this.frameService});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final Logger _log = Logger('FeedScreen');
  String _displayText = 'Loading...';
  List<int>? _photoData;

  @override
  void initState() {
    super.initState();
    _log.info('feed screen initstate called');
    _fetchDisplayText();
  }

  Future<void> _fetchDisplayText() async {
    _log.info('fetching display text');
    try {
      final text = await widget.frameService.getDisplayText();
      setState(() {
        _displayText = text ?? 'No text available';
      });
      _log.info('fetched display text: $_displayText');
    } catch (e) {
      _log.severe('error fetching display text: $e');
      setState(() {
        _displayText = 'Error: $e';
      });
    }
  }

  Future<void> _capturePhoto() async {
    _log.info('capture photo button pressed');
    try {
      final photo = await widget.frameService.capturePhoto();
      if (photo != null && photo.isNotEmpty) {
        setState(() {
          _photoData = photo;
        });
        _log.info('photo captured, length: ${photo.length}');
      } else {
        _log.warning('no photo data captured');
        setState(() {
          _displayText = 'No photo data';
        });
      }
    } catch (e) {
      _log.severe('error capturing photo: $e');
      setState(() {
        _displayText = 'Error capturing photo: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _log.info('building feed screen, photo data: ${_photoData != null}');
    return Column(
      children: [
        Expanded(
          child: _photoData == null
              ? Center(child: Text('Press button to capture photo'))
              : _photoData!.isEmpty
              ? Center(child: Text('No image data'))
              : Image.memory(
            Uint8List.fromList(_photoData!),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              _log.severe('error displaying image: $error', error, stackTrace);
              return Center(child: Text('Error displaying image: $error'));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Text(_displayText),
              ElevatedButton(
                onPressed: widget.frameService.isConnected ? _capturePhoto : null,
                child: const Text('Capture Photo'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}