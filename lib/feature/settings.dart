import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../services/api_response_manager.dart';
final _log = Logger("SettingsScreen");

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  SettingsScreenState createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiEndpointController = TextEditingController();
  final TextEditingController _framesToQueueController = TextEditingController();

  // API-related controllers
  final TextEditingController _apiUsernameController = TextEditingController();
  final TextEditingController _apiAuthKeyController = TextEditingController();
  final TextEditingController _deepSeekApiKeyController = TextEditingController();
  final TextEditingController _qwenApiKeyController = TextEditingController();
  final TextEditingController _geminiApiKeyController = TextEditingController();
  final TextEditingController _chatGptApiKeyController = TextEditingController();

  // NEW: Custom prompt controller
  final TextEditingController _customPromptController = TextEditingController();
  final ApiResponseManager _apiManager = ApiResponseManager();

  String _selectedCameraQuality = 'Medium';
  bool _processFramesWithApi = false;
  bool _isUpdatingPrompt = false; // Loading state for prompt update

  int _qualityIndex = 2;
  final List<String> _qualityValues = ['VERY_LOW', 'LOW', 'MEDIUM', 'HIGH', 'VERY_HIGH'];
  int _resolution = 720;
  int _pan = 0;
  bool _isAutoExposure = true;

  int _meteringIndex = 1;
  final List<String> _meteringValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  double _exposure = 0.1;
  double _exposureSpeed = 0.45;
  int _shutterLimit = 16383;
  int _analogGainLimit = 16;
  double _whiteBalanceSpeed = 0.5;
  int _rgbGainLimit = 287;

  int _manualShutter = 4096;
  int _manualAnalogGain = 1;
  int _manualRedGain = 121;
  int _manualGreenGain = 64;
  int _manualBlueGain = 140;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _apiEndpointController.dispose();
    _framesToQueueController.dispose();
    _apiUsernameController.dispose();
    _apiAuthKeyController.dispose();
    _deepSeekApiKeyController.dispose();
    _qwenApiKeyController.dispose();
    _geminiApiKeyController.dispose();
    _chatGptApiKeyController.dispose();
    _customPromptController.dispose(); // NEW
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _apiEndpointController.text = prefs.getString('api_endpoint') ?? '';
      _framesToQueueController.text = (prefs.getInt('frames_to_queue') ?? 5).toString();

      // Load API settings
      _apiUsernameController.text = prefs.getString('api_username') ?? '';
      _apiAuthKeyController.text = prefs.getString('api_auth_key') ?? '';
      _deepSeekApiKeyController.text = prefs.getString('deepseek_api_key') ?? '';
      _qwenApiKeyController.text = prefs.getString('qwen_api_key') ?? '';
      _geminiApiKeyController.text = prefs.getString('gemini_api_key') ?? '';
      _chatGptApiKeyController.text = prefs.getString('chatgpt_api_key') ?? '';

      // NEW: Load custom prompt
      _customPromptController.text = prefs.getString('custom_prompt') ?? 'Describe this image in detail, if it has words in another language besides english translate it back to english and provide me with the result in the format "Translated Text: xyz", if it contains a math problem or word problem provide me with the result in the format "Problem: xyz"';

      _selectedCameraQuality = prefs.getString('camera_quality') ?? 'Medium';
      _processFramesWithApi = prefs.getBool('process_frames_with_api') ?? false;

      _qualityIndex = prefs.getInt('camera_quality_index') ?? 2;
      _resolution = prefs.getInt('camera_resolution') ?? 720;
      _pan = prefs.getInt('camera_pan') ?? 0;
      _isAutoExposure = prefs.getBool('camera_auto_exposure') ?? true;

      _meteringIndex = prefs.getInt('camera_metering_index') ?? 1;
      _exposure = prefs.getDouble('camera_exposure') ?? 0.1;
      _exposureSpeed = prefs.getDouble('camera_exposure_speed') ?? 0.45;
      _shutterLimit = prefs.getInt('camera_shutter_limit') ?? 16383;
      _analogGainLimit = prefs.getInt('camera_analog_gain_limit') ?? 16;
      _whiteBalanceSpeed = prefs.getDouble('camera_white_balance_speed') ?? 0.5;
      _rgbGainLimit = prefs.getInt('camera_rgb_gain_limit') ?? 287;

      _manualShutter = prefs.getInt('camera_manual_shutter') ?? 4096;
      _manualAnalogGain = prefs.getInt('camera_manual_analog_gain') ?? 1;
      _manualRedGain = prefs.getInt('camera_manual_red_gain') ?? 121;
      _manualGreenGain = prefs.getInt('camera_manual_green_gain') ?? 64;
      _manualBlueGain = prefs.getInt('camera_manual_blue_gain') ?? 140;

      _log.info("All settings loaded successfully");
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('api_endpoint', _apiEndpointController.text);
    await prefs.setInt('frames_to_queue', int.tryParse(_framesToQueueController.text) ?? 5);

    // Save API settings
    await prefs.setString('api_username', _apiUsernameController.text);
    await prefs.setString('api_auth_key', _apiAuthKeyController.text);
    await prefs.setString('deepseek_api_key', _deepSeekApiKeyController.text);
    await prefs.setString('qwen_api_key', _qwenApiKeyController.text);
    await prefs.setString('gemini_api_key', _geminiApiKeyController.text);
    await prefs.setString('chatgpt_api_key', _chatGptApiKeyController.text);

    // NEW: Save custom prompt
    await prefs.setString('custom_prompt', _customPromptController.text);

    await prefs.setString('camera_quality', _selectedCameraQuality);
    await prefs.setBool('process_frames_with_api', _processFramesWithApi);

    await prefs.setInt('camera_quality_index', _qualityIndex);
    await prefs.setInt('camera_resolution', _resolution);
    await prefs.setInt('camera_pan', _pan);
    await prefs.setBool('camera_auto_exposure', _isAutoExposure);

    await prefs.setInt('camera_metering_index', _meteringIndex);
    await prefs.setDouble('camera_exposure', _exposure);
    await prefs.setDouble('camera_exposure_speed', _exposureSpeed);
    await prefs.setInt('camera_shutter_limit', _shutterLimit);
    await prefs.setInt('camera_analog_gain_limit', _analogGainLimit);
    await prefs.setDouble('camera_white_balance_speed', _whiteBalanceSpeed);
    await prefs.setInt('camera_rgb_gain_limit', _rgbGainLimit);

    await prefs.setInt('camera_manual_shutter', _manualShutter);
    await prefs.setInt('camera_manual_analog_gain', _manualAnalogGain);
    await prefs.setInt('camera_manual_red_gain', _manualRedGain);
    await prefs.setInt('camera_manual_green_gain', _manualGreenGain);
    await prefs.setInt('camera_manual_blue_gain', _manualBlueGain);

    // Set a flag to indicate settings changed
    await prefs.setBool('camera_settings_changed', true);

    _log.info("All settings saved successfully");

    // NEW: Update prompt on server after saving locally
    await _updatePromptOnServer();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved!')),
      );
    }
  }

  // NEW: Update prompt on server
  Future<void> _updatePromptOnServer() async {
    final customPrompt = _customPromptController.text.trim();

    if (customPrompt.isEmpty) {
      _log.warning("Custom prompt empty, skipping server update");
      return;
    }

    setState(() {
      _isUpdatingPrompt = true;
    });

    try {
      await _apiManager.initialize();
      final success = await _apiManager.updatePrompt(customPrompt);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'Custom prompt updated on server!' : 'Failed to update prompt'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      _log.severe("Error updating prompt on server: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating prompt: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUpdatingPrompt = false;
        });
      }
    }
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.blueAccent,
        ),
      ),
    );
  }

  Widget _buildSliderTile({
    required String title,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    String? subtitle,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) Text(subtitle),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: value.toStringAsFixed(divisions != null ? 0 : 2),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildIntSliderTile({
    required String title,
    required int value,
    required int min,
    required int max,
    int? divisions,
    required ValueChanged<int> onChanged,
    String? subtitle,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) Text(subtitle),
          Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions ?? (max - min),
            label: value.toString(),
            onChanged: (double val) => onChanged(val.toInt()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: () => _resetToDefaults(),
            child: const Text('Reset', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('Server Configuration'),
            TextField(
              controller: _apiEndpointController,
              decoration: const InputDecoration(
                labelText: 'API Endpoint',
                hintText: 'e.g. http://192.168.0.5:7175',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiUsernameController,
              decoration: const InputDecoration(
                labelText: 'API Username',
                hintText: 'Your username for the server',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiAuthKeyController,
              decoration: const InputDecoration(
                labelText: 'API Authentication Key',
                hintText: 'Authentication key for server access',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              obscureText: true,
            ),

            _buildSectionHeader('AI Configuration'),

            // NEW: Custom Prompt Field
            TextField(
              controller: _customPromptController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Custom AI Prompt',
                hintText: 'e.g. "Analyze this image for cooking ingredients and suggest a recipe"',
                helperText: 'This prompt will be sent to the AI services when processing images',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                suffixIcon: _isUpdatingPrompt
                    ? const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
                    : IconButton(
                  icon: const Icon(Icons.cloud_upload),
                  onPressed: _updatePromptOnServer,
                  tooltip: 'Update prompt on server',
                ),
              ),
              onChanged: (value) {
                // Auto-save locally when user types (with debouncing would be better)
                SharedPreferences.getInstance().then((prefs) {
                  prefs.setString('custom_prompt', value);
                });
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isUpdatingPrompt ? null : _updatePromptOnServer,
                    icon: _isUpdatingPrompt
                        ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                        : const Icon(Icons.sync),
                    label: Text(_isUpdatingPrompt ? 'Updating...' : 'Update Prompt on Server'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    _customPromptController.text = 'Describe this image in detail';
                    SharedPreferences.getInstance().then((prefs) {
                      prefs.setString('custom_prompt', 'Describe this image in detail');
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade600,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            _buildSectionHeader('AI API Keys'),
            TextField(
              controller: _deepSeekApiKeyController,
              decoration: const InputDecoration(
                labelText: 'DeepSeek API Key',
                hintText: 'Your DeepSeek API key',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _qwenApiKeyController,
              decoration: const InputDecoration(
                labelText: 'Qwen API Key',
                hintText: 'Your Qwen API key',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _geminiApiKeyController,
              decoration: const InputDecoration(
                labelText: 'Gemini API Key',
                hintText: 'Your Google Gemini API key',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _chatGptApiKeyController,
              decoration: const InputDecoration(
                labelText: 'ChatGPT API Key',
                hintText: 'Your OpenAI ChatGPT API key',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.text,
              obscureText: true,
            ),

            _buildSectionHeader('Processing Configuration'),
            TextField(
              controller: _framesToQueueController,
              decoration: const InputDecoration(
                labelText: 'Frames to Queue for Video Processing',
                hintText: 'e.g. 5',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedCameraQuality,
              decoration: const InputDecoration(
                labelText: 'Camera Quality',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              items: <String>['Low', 'Medium', 'High']
                  .map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (String? newValue) {
                if (newValue != null) {
                  setState(() {
                    _selectedCameraQuality = newValue;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Process Frames with API'),
              value: _processFramesWithApi,
              onChanged: (bool value) {
                setState(() {
                  _processFramesWithApi = value;
                });
              },
              secondary: const Icon(Icons.cloud_upload),
            ),

            // Rest of the camera settings remain the same...
            _buildSectionHeader('Camera Settings'),
            _buildIntSliderTile(
              title: 'Quality',
              value: _qualityIndex,
              min: 0,
              max: _qualityValues.length - 1,
              divisions: _qualityValues.length - 1,
              subtitle: _qualityValues[_qualityIndex],
              onChanged: (value) {
                setState(() {
                  _qualityIndex = value;
                });
              },
            ),
            _buildIntSliderTile(
              title: 'Resolution',
              value: _resolution,
              min: 256,
              max: 720,
              divisions: (720 - 256) ~/ 16,
              subtitle: _resolution.toString(),
              onChanged: (value) {
                setState(() {
                  _resolution = value;
                });
              },
            ),
            _buildIntSliderTile(
              title: 'Pan',
              value: _pan,
              min: -140,
              max: 140,
              divisions: 280,
              subtitle: _pan.toString(),
              onChanged: (value) {
                setState(() {
                  _pan = value;
                });
              },
            ),
            SwitchListTile(
              title: const Text('Auto Exposure/Gain'),
              value: _isAutoExposure,
              onChanged: (bool value) {
                setState(() {
                  _isAutoExposure = value;
                });
              },
              subtitle: Text(_isAutoExposure ? 'Auto' : 'Manual'),
              secondary: const Icon(Icons.auto_fix_high),
            ),

            if (_isAutoExposure) ...[
              _buildSectionHeader('Auto Exposure Settings'),
              ListTile(
                title: const Text('Metering'),
                subtitle: DropdownButton<int>(
                  value: _meteringIndex,
                  isExpanded: true,
                  onChanged: (int? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _meteringIndex = newValue;
                      });
                    }
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
              _buildSliderTile(
                title: 'Exposure',
                value: _exposure,
                min: 0,
                max: 1,
                divisions: 20,
                subtitle: _exposure.toString(),
                onChanged: (value) {
                  setState(() {
                    _exposure = value;
                  });
                },
              ),
              _buildSliderTile(
                title: 'Exposure Speed',
                value: _exposureSpeed,
                min: 0,
                max: 1,
                divisions: 20,
                subtitle: _exposureSpeed.toString(),
                onChanged: (value) {
                  setState(() {
                    _exposureSpeed = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Shutter Limit',
                value: _shutterLimit,
                min: 4,
                max: 16383,
                divisions: 16,
                subtitle: _shutterLimit.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _shutterLimit = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Analog Gain Limit',
                value: _analogGainLimit,
                min: 1,
                max: 248,
                divisions: 16,
                subtitle: _analogGainLimit.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _analogGainLimit = value;
                  });
                },
              ),
              _buildSliderTile(
                title: 'White Balance Speed',
                value: _whiteBalanceSpeed,
                min: 0,
                max: 1,
                divisions: 20,
                subtitle: _whiteBalanceSpeed.toString(),
                onChanged: (value) {
                  setState(() {
                    _whiteBalanceSpeed = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'RGB Gain Limit',
                value: _rgbGainLimit,
                min: 0,
                max: 1023,
                divisions: 32,
                subtitle: _rgbGainLimit.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _rgbGainLimit = value;
                  });
                },
              ),
            ] else ...[
              _buildSectionHeader('Manual Exposure Settings'),
              _buildIntSliderTile(
                title: 'Manual Shutter',
                value: _manualShutter,
                min: 4,
                max: 16383,
                divisions: 32,
                subtitle: _manualShutter.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _manualShutter = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Manual Analog Gain',
                value: _manualAnalogGain,
                min: 1,
                max: 248,
                divisions: 50,
                subtitle: _manualAnalogGain.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _manualAnalogGain = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Red Gain',
                value: _manualRedGain,
                min: 0,
                max: 1023,
                divisions: 50,
                subtitle: _manualRedGain.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _manualRedGain = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Green Gain',
                value: _manualGreenGain,
                min: 0,
                max: 1023,
                divisions: 50,
                subtitle: _manualGreenGain.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _manualGreenGain = value;
                  });
                },
              ),
              _buildIntSliderTile(
                title: 'Blue Gain',
                value: _manualBlueGain,
                min: 0,
                max: 1023,
                divisions: 50,
                subtitle: _manualBlueGain.toStringAsFixed(0),
                onChanged: (value) {
                  setState(() {
                    _manualBlueGain = value;
                  });
                },
              ),
            ],

            const SizedBox(height: 30),
            Center(
              child: ElevatedButton(
                onPressed: _saveSettings,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 5,
                ),
                child: const Text(
                  'Save Settings',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _resetToDefaults() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Settings'),
        content: const Text('Are you sure you want to reset all settings to their default values?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              setState(() {
                _apiEndpointController.text = '';
                _framesToQueueController.text = '5';
                _apiUsernameController.text = '';
                _apiAuthKeyController.text = '';
                _deepSeekApiKeyController.text = '';
                _qwenApiKeyController.text = '';
                _geminiApiKeyController.text = '';
                _chatGptApiKeyController.text = '';
                _customPromptController.text = 'Describe this image in detail'; // NEW: Reset prompt
                _selectedCameraQuality = 'Medium';
                _processFramesWithApi = false;

                _qualityIndex = 2;
                _resolution = 720;
                _pan = 0;
                _isAutoExposure = true;
                _meteringIndex = 1;
                _exposure = 0.1;
                _exposureSpeed = 0.45;
                _shutterLimit = 16383;
                _analogGainLimit = 16;
                _whiteBalanceSpeed = 0.5;
                _rgbGainLimit = 287;
                _manualShutter = 4096;
                _manualAnalogGain = 1;
                _manualRedGain = 121;
                _manualGreenGain = 64;
                _manualBlueGain = 140;
              });
              await _saveSettings();
              Navigator.pop(context);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}