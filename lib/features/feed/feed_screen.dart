import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import '../../services/frame_service.dart';

class FeedScreen extends StatefulWidget {
  final FrameService frameService;

  const FeedScreen({super.key, required this.frameService});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final Logger _log = Logger('FeedScreen');
  StreamSubscription<Uint8List>? _feedSubscription;
  Uint8List? _liveFrame;
  final List<(Uint8List, ImageMetadata)> _photos = [];
  bool _showLiveFeed = false;
  bool _isCapturing = false;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    // Listen to connection state changes
    widget.frameService.connectionState.addListener(_onConnectionStateChanged);
    // Initialize connection
    _initializeConnection();
  }

  Future<void> _initializeConnection() async {
    try {
      await widget.frameService.connectToGlasses();
      setState(() {
        _isConnected = widget.frameService.connectionState.value;
      });
    } catch (e) {
      _log.severe('Failed to connect to Frame glasses: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect to Frame glasses: $e')),
        );
      }
    }
  }

  void _onConnectionStateChanged() {
    setState(() {
      _isConnected = widget.frameService.connectionState.value;
    });
    if (!_isConnected && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected from Frame glasses')),
      );
      _initializeConnection();
    }
  }

  Future<void> _startLiveFeed() async {
    if (!_isConnected) {
      _log.warning('Not connected to glasses');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected to glasses. Connecting...')),
        );
      }
      await _initializeConnection();
      if (!_isConnected) {
        _log.severe('Failed to connect to glasses');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to connect to glasses')),
          );
        }
        return;
      }
    }
    try {
      await widget.frameService.sendExposureSettings();
      _feedSubscription?.cancel();
      _feedSubscription = widget.frameService.getLiveFeedStream().listen(
            (imageData) {
          setState(() {
            _liveFrame = imageData;
          });
        },
        onError: (e) {
          _log.severe('Live feed error: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Live feed error: $e')),
            );
          }
          setState(() {
            _showLiveFeed = false;
            _liveFrame = null;
          });
        },
      );
      _log.info('Live feed started');
    } catch (e) {
      _log.severe('Failed to start live feed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start live feed: $e')),
        );
      }
      setState(() {
        _showLiveFeed = false;
        _liveFrame = null;
      });
    }
  }

  Future<void> _capturePhoto() async {
    if (!_isConnected) {
      _log.warning('Not connected to glasses');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected to glasses')),
        );
      }
      return;
    }
    if (_isCapturing) {
      _log.info('Capture in progress, ignoring request');
      return;
    }
    setState(() {
      _isCapturing = true;
    });
    try {
      final (imageData, meta) = await widget.frameService.capturePhoto();
      if (!mounted) return;
      setState(() {
        _photos.insert(0, (imageData, meta));
        _isCapturing = false;
      });
      _log.info('Photo captured: ${imageData.length} bytes');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo captured: ${imageData.length} bytes')),
        );
      }
    } catch (e) {
      _log.severe('Capture failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
      setState(() {
        _isCapturing = false;
      });
    }
  }

  @override
  void dispose() {
    _feedSubscription?.cancel();
    widget.frameService.connectionState.removeListener(_onConnectionStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Frame Feed'),
        actions: [
          IconButton(
            icon: Icon(_isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled),
            onPressed: _isConnected ? null : _initializeConnection,
            tooltip: _isConnected ? 'Connected' : 'Reconnect',
          ),
        ],
      ),
      body: Column(
        children: [
          // Live Feed Section
          if (_showLiveFeed)
            Container(
              height: 200,
              color: Colors.black12,
              child: _liveFrame != null
                  ? Image.memory(
                _liveFrame!,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Center(child: Text('Error loading live feed'));
                },
              )
                  : const Center(child: CircularProgressIndicator()),
            ),
          // Feed Section
          Expanded(
            child: _photos.isEmpty && !_showLiveFeed
                ? const Center(child: Text('No photos yet. Capture one!'))
                : ListView.builder(
              itemCount: _photos.length,
              itemBuilder: (context, index) {
                final (imageData, metadata) = _photos[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Image.memory(
                        imageData,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(child: Text('Error loading image'));
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: metadata.toMetaDataList().asMap().entries.map((entry) {
                            return Text(
                              entry.value,
                              style: Theme.of(context).textTheme.bodySmall,
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // Control Buttons
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isConnected
                      ? () async {
                    setState(() {
                      _showLiveFeed = !_showLiveFeed;
                    });
                    if (_showLiveFeed) {
                      await _startLiveFeed();
                    } else {
                      _feedSubscription?.cancel();
                      setState(() {
                        _liveFrame = null;
                      });
                    }
                  }
                      : null,
                  child: Text(_showLiveFeed ? 'Stop Live Feed' : 'Start Live Feed'),
                ),
                ElevatedButton(
                  onPressed: _isCapturing || !_isConnected ? null : _capturePhoto,
                  child: _isCapturing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Capture Photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}