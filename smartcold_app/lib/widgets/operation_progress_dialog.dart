import 'package:flutter/material.dart';

enum ProgressStepState { pending, running, success, error }

class ProgressStepData {
  ProgressStepData({
    required this.title,
    this.state = ProgressStepState.pending,
  });

  final String title;
  ProgressStepState state;
}

class OperationProgressDialog extends StatelessWidget {
  const OperationProgressDialog({
    super.key,
    required this.title,
    required this.steps,
  });

  final String title;
  final List<ProgressStepData> steps;

  IconData _icon(ProgressStepState state) {
    switch (state) {
      case ProgressStepState.pending:
        return Icons.radio_button_unchecked;
      case ProgressStepState.running:
        return Icons.hourglass_top_rounded;
      case ProgressStepState.success:
        return Icons.check_circle_rounded;
      case ProgressStepState.error:
        return Icons.cancel_rounded;
    }
  }

  Color _color(ProgressStepState state) {
    switch (state) {
      case ProgressStepState.pending:
        return Colors.grey;
      case ProgressStepState.running:
        return Colors.orange;
      case ProgressStepState.success:
        return Colors.green;
      case ProgressStepState.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF061A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: steps.map((step) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(_icon(step.state), color: _color(step.state)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      step.title,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
