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

  // NEW: Camera-specific additions
  StreamSubscription<Uint8List>? _cameraSubscription;
  final List<Uint8List> _framePhotos = [];
  bool _isContinuousCapture = false;

  @override
  void initState() {
    super.initState();
    // Listen to connection state changes
    widget.frameService.connectionState.addListener(_onConnectionStateChanged);
    // Initialize connection
    _initializeConnection();
    // NEW: Initialize camera stream
    _initializeCameraStream();
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

  // NEW: Initialize camera stream listener
  void _initializeCameraStream() {
    _cameraSubscription = widget.frameService.cameraStream.listen(
          (imageData) {
        if (mounted) {
          setState(() {
            _framePhotos.insert(0, imageData);
            // Keep only last 20 photos to prevent memory issues
            if (_framePhotos.length > 20) {
              _framePhotos.removeLast();
            }
          });
          _log.info('Received camera image: ${imageData.length} bytes');
        }
      },
      onError: (error) {
        _log.severe('Camera stream error: $error');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Camera stream error: $error')),
          );
        }
      },
    );
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

  // NEW: Simple Frame camera capture
  Future<void> _captureFramePhoto() async {
    if (!_isConnected || !widget.frameService.isCameraReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Frame camera not ready')),
        );
      }
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final imageData = await widget.frameService.captureSimplePhoto();
      if (imageData != null && mounted) {
        setState(() {
          _framePhotos.insert(0, imageData);
          if (_framePhotos.length > 20) {
            _framePhotos.removeLast();
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Frame photo captured: ${imageData.length} bytes')),
        );
      }
    } catch (e) {
      _log.severe('Frame capture failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Frame capture failed: $e')),
        );
      }
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
  }

  // NEW: Toggle continuous Frame capture
  Future<void> _toggleContinuousCapture() async {
    if (!_isConnected || !widget.frameService.isCameraReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Frame camera not ready')),
        );
      }
      return;
    }

    setState(() {
      _isContinuousCapture = !_isContinuousCapture;
    });

    if (_isContinuousCapture) {
      await widget.frameService.startContinuousCapture(intervalMs: 3000);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Started continuous Frame capture')),
        );
      }
    } else {
      // Note: The FrameService handles stopping internally
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Stopped continuous Frame capture')),
        );
      }
    }
  }

  @override
  void dispose() {
    _feedSubscription?.cancel();
    _cameraSubscription?.cancel();
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
          // NEW: Camera status indicator
          IconButton(
            icon: Icon(
              widget.frameService.isCameraReady ? Icons.camera_alt : Icons.camera_alt_outlined,
              color: widget.frameService.isCameraReady ? Colors.green : Colors.grey,
            ),
            onPressed: null,
            tooltip: widget.frameService.isCameraReady ? 'Camera Ready' : 'Camera Not Ready',
          ),
        ],
      ),
      body: Column(
        children: [
          // Live Feed Section (existing)
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

          // NEW: Frame Camera Preview Section
          if (_framePhotos.isNotEmpty)
            Container(
              height: 200,
              color: Colors.blue.shade50,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        Icon(Icons.camera, color: Colors.blue),
                        SizedBox(width: 8),
                        Text(
                          'Frame Camera (${_framePhotos.length} photos)',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade800),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      itemCount: _framePhotos.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Image.memory(
                            _framePhotos[index],
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return const Center(child: Text('Error loading Frame image'));
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

          // Feed Section (existing structure preserved)
          Expanded(
            child: _photos.isEmpty && !_showLiveFeed && _framePhotos.isEmpty
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

          // Control Buttons (enhanced with new Frame camera controls)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                // Existing controls
                Row(
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

                // NEW: Frame camera controls
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: (_isCapturing || !_isConnected || !widget.frameService.isCameraReady)
                          ? null
                          : _captureFramePhoto,
                      icon: Icon(Icons.camera_alt),
                      label: Text('Frame Photo'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: (!_isConnected || !widget.frameService.isCameraReady)
                          ? null
                          : _toggleContinuousCapture,
                      icon: Icon(_isContinuousCapture ? Icons.stop : Icons.play_arrow),
                      label: Text(_isContinuousCapture ? 'Stop Auto' : 'Start Auto'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isContinuousCapture ? Colors.red.shade600 : Colors.green.shade600,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}