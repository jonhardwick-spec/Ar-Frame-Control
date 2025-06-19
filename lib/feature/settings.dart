import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger("SettingsScreen");

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  SettingsScreenState createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiEndpointController = TextEditingController();
  final TextEditingController _framesToQueueController = TextEditingController();
  String _selectedCameraQuality = 'Medium'; // Default value
  bool _processFramesWithApi = false; // New setting for API processing toggle

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _apiEndpointController.dispose();
    _framesToQueueController.dispose();
    super.dispose();
  }

  // Loads settings from SharedPreferences
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _apiEndpointController.text = prefs.getString('api_endpoint') ?? '';
      _framesToQueueController.text = (prefs.getInt('frames_to_queue') ?? 5).toString(); // Default to 5 frames
      _selectedCameraQuality = prefs.getString('camera_quality') ?? 'Medium'; // Default to Medium
      _processFramesWithApi = prefs.getBool('process_frames_with_api') ?? false; // Default to false
    });
  }

  // Saves settings to SharedPreferences
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_endpoint', _apiEndpointController.text);
    await prefs.setInt('frames_to_queue', int.tryParse(_framesToQueueController.text) ?? 5);
    await prefs.setString('camera_quality', _selectedCameraQuality);
    await prefs.setBool('process_frames_with_api', _processFramesWithApi); // Save the new setting
    _log.info("Settings saved: API Endpoint: ${_apiEndpointController.text}, Frames to Queue: ${_framesToQueueController.text}, Camera Quality: $_selectedCameraQuality, Process with API: $_processFramesWithApi");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // API Endpoint Setting
              const Text('API Endpoint:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _apiEndpointController,
                decoration: const InputDecoration(
                  hintText: 'e.g. http://192.168.0.5:8000/process',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 20),

              // Frames to Queue Setting
              const Text('Frames to Queue for Video Processing:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _framesToQueueController,
                decoration: const InputDecoration(
                  hintText: 'e.g. 5',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 20),

              // Camera Quality Setting
              const Text('Camera Quality:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _selectedCameraQuality,
                decoration: const InputDecoration(
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
              const SizedBox(height: 20),

              // Toggle for API processing
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
              const SizedBox(height: 10),

              // Save Button
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
            ],
          ),
        ),
      ),
    );
  }
}