import 'package:flutter/material.dart';

class SupportTile extends StatelessWidget {
  const SupportTile({
    super.key,
    required this.label,
    required this.minimum,
    required this.isSupported,
  });

  final String label;
  final String minimum;
  final bool? isSupported;

  @override
  Widget build(BuildContext context) {
    final supported = isSupported == true;
    final unknown = isSupported == null;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        unknown
            ? Icons.help_outline_rounded
            : supported
                ? Icons.check_circle_outline_rounded
                : Icons.highlight_off_rounded,
        color: unknown
            ? null
            : supported
                ? Colors.greenAccent
                : Theme.of(context).colorScheme.error,
      ),
      title: Text(label),
      subtitle: Text(minimum),
      trailing: Text(
        unknown
            ? 'Unknown'
            : supported
                ? 'Available'
                : 'Unavailable',
      ),
    );
  }
}
