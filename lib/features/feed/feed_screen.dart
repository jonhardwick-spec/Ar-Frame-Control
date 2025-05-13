import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/frame_service.dart';
import '../../services/feed_service.dart';

class FeedScreen extends StatefulWidget {
  final FrameService frameService;
  final FeedService feedService;

  const FeedScreen({super.key, required this.frameService, required this.feedService});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  StreamSubscription<Uint8List>? _feedSubscription;
  Uint8List? _currentFrame;
  bool _showLiveFeed = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _startLiveFeed() async {
    if (!widget.frameService.connectionState.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to glasses. Connecting...')),
      );
      await widget.frameService.connectToGlasses();
      if (!widget.frameService.connectionState.value) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to connect to glasses')),
        );
        return;
      }
    }
    try {
      await widget.feedService.sendExposureSettings();
      _feedSubscription?.cancel();
      _feedSubscription = widget.feedService.getLiveFeedStream().listen(
            (imageData) {
          setState(() {
            _currentFrame = imageData;
          });
        },
        onError: (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Live feed error: $e')),
          );
          setState(() {
            _showLiveFeed = false;
          });
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start live feed: $e')),
      );
      setState(() {
        _showLiveFeed = false;
      });
    }
  }

  Future<void> _capturePhoto() async {
    if (!widget.frameService.connectionState.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to glasses')),
      );
      return;
    }
    if (_isCapturing) return;
    setState(() {
      _isCapturing = true;
      _currentFrame = null;
    });
    try {
      final (imageData, meta) = await widget.feedService.capturePhoto();
      if (!mounted) return;
      setState(() {
        _currentFrame = imageData;
        _isCapturing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo captured: ${imageData.length} bytes')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCapturing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _feedSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: _currentFrame != null
                ? Image.memory(
              _currentFrame!,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Center(child: Text('Error loading image'));
              },
            )
                : Center(
              child: _isCapturing
                  ? const CircularProgressIndicator()
                  : const Text('No feed available'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    setState(() {
                      _showLiveFeed = !_showLiveFeed;
                    });
                    if (_showLiveFeed) {
                      await _startLiveFeed();
                    } else {
                      _feedSubscription?.cancel();
                      setState(() {
                        _currentFrame = null;
                      });
                    }
                  },
                  child: Text(_showLiveFeed ? 'Stop Live Feed' : 'Start Live Feed'),
                ),
                ElevatedButton(
                  onPressed: _capturePhoto,
                  child: const Text('Capture Photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}