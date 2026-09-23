import 'package:flutter/material.dart';

class UpdatePrompt extends StatelessWidget {
  const UpdatePrompt({
    required this.version,
    required this.onInstall,
    super.key,
  });

  final String version;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Update Available'),
      content: Text(
        'Version $version is ready to install. Android will ask you to '
        'confirm before installing.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            onInstall();
          },
          child: const Text('Install'),
        ),
      ],
    );
  }
}
