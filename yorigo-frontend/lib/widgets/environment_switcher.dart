import 'package:flutter/material.dart';
import '../config/environment_config.dart';

/// A debug widget to manually switch environments
/// Only shows in debug mode - will be removed in release builds
class EnvironmentSwitcher extends StatefulWidget {
  const EnvironmentSwitcher({super.key});

  @override
  State<EnvironmentSwitcher> createState() => _EnvironmentSwitcherState();
}

class _EnvironmentSwitcherState extends State<EnvironmentSwitcher> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bug_report, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Text(
                'Developer Settings',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Current: ${EnvironmentConfig.currentEnvironment.name}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            'URL: ${EnvironmentConfig.baseUrl}',
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          const Text(
            'Switch Environment:',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _buildEnvButton(
                'Auto',
                null,
                Colors.grey,
                onPressed: () {
                  setState(() {
                    EnvironmentConfig.resetEnvironment();
                  });
                  _showSnackbar('Switched to automatic detection');
                },
              ),
              _buildEnvButton(
                'Local',
                Environment.local,
                Colors.blue,
                onPressed: () {
                  setState(() {
                    EnvironmentConfig.setEnvironment(Environment.local);
                  });
                  _showSnackbar(
                    'Switched to Local (${EnvironmentConfig.baseUrl})',
                  );
                },
              ),
              _buildEnvButton(
                'Mobile',
                Environment.mobileTesting,
                Colors.green,
                onPressed: () {
                  setState(() {
                    EnvironmentConfig.setEnvironment(Environment.mobileTesting);
                  });
                  _showSnackbar(
                    'Switched to Mobile Testing (${EnvironmentConfig.baseUrl})',
                  );
                },
              ),
              _buildEnvButton(
                'Prod',
                Environment.production,
                Colors.red,
                onPressed: () {
                  setState(() {
                    EnvironmentConfig.setEnvironment(Environment.production);
                  });
                  _showSnackbar(
                    'Switched to Production (${EnvironmentConfig.baseUrl})',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Custom URL',
                    hintText: 'http://192.168.1.100:8000',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  final url = _urlController.text.trim();
                  if (url.isNotEmpty) {
                    setState(() {
                      EnvironmentConfig.setMobileTestingUrl(url);
                      EnvironmentConfig.setEnvironment(
                        Environment.mobileTesting,
                      );
                    });
                    _showSnackbar('Custom URL set: $url');
                    _urlController.clear();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  minimumSize: const Size(0, 0),
                ),
                child: const Text('Set', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () {
              EnvironmentConfig.printConfig();
              _showSnackbar('Configuration printed to console');
            },
            icon: const Icon(Icons.print, size: 16),
            label: const Text(
              'Print Config to Console',
              style: TextStyle(fontSize: 11),
            ),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnvButton(
    String label,
    Environment? env,
    Color color, {
    required VoidCallback onPressed,
  }) {
    final isActive = env == null
        ? EnvironmentConfig.currentEnvironment ==
              EnvironmentConfig.currentEnvironment
        : EnvironmentConfig.currentEnvironment == env;

    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: isActive ? color : Colors.grey.shade300,
        foregroundColor: isActive ? Colors.white : Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: const Size(0, 0),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
