import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:ar_project/services/frame_service.dart';

class Feed extends StatefulWidget {
  final FrameService frameService;

  const Feed({super.key, required this.frameService});

  @override
  State<Feed> createState() => _FeedState();
}

class _FeedState extends State<Feed> {
  final Logger _log = Logger('Feed');
  String _displayText = 'Loading...';
  List<int>? _photoData;

  @override
  void initState() {
    super.initState();
    _fetchDisplayText();
  }

  Future<void> _fetchDisplayText() async {
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
    try {
      final photo = await widget.frameService.capturePhoto();
      if (photo != null && photo.isNotEmpty) {
        setState(() {
          _photoData = photo;
        });
        _log.info('photo captured, length: ${photo.length}');
      } else {
        _log.warning('no photo data captured');
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
              _log.severe('error displaying image: $error');
              return Center(child: Text('Error displaying image: $error'));
            },
          ),
        ),
        Padding(
          padding: EdgeInsets.all(8.0),
          child: Column(
            children: [
              Text(_displayText),
              ElevatedButton(
                onPressed: widget.frameService.isConnected ? _capturePhoto : null,
                child: Text('Capture Photo'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}