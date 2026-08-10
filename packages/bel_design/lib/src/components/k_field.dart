import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// A text field.
///
/// The error sits **below** the field and pushes content down rather than
/// overlaying it. An error that covers the next control is an error that
/// hides the way out of itself.
final class KField extends StatelessWidget {
  const KField({
    required this.label,
    this.controller,
    this.hint,
    this.error,
    this.helper,
    this.keyboardType,
    this.prefix,
    this.onChanged,
    this.enabled = true,
    this.autofocus = false,
    this.maxLength,
    this.maxLines = 1,
    super.key,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? error;
  final String? helper;
  final TextInputType? keyboardType;
  final Widget? prefix;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool autofocus;
  final int? maxLength;

  /// More than one turns this into a note field. The back office needs one:
  /// "say exactly what is missing" does not fit on a line, and a reviewer who
  /// cannot see what they typed writes less of it.
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final invalid = error != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: kilo.text.label.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),
        Container(
          decoration: BoxDecoration(
            color: enabled
                ? kilo.color.surfaceRaised
                : kilo.color.surfaceSunken,
            borderRadius: kilo.radius.controlBorder,
            border: Border.all(
              color: invalid ? kilo.color.danger : kilo.color.borderStrong,
              width: invalid ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (prefix != null)
                Padding(
                  padding: EdgeInsets.only(left: kilo.space.s3),
                  child: prefix,
                ),
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  autofocus: autofocus,
                  keyboardType: keyboardType,
                  onChanged: onChanged,
                  maxLength: maxLength,
                  maxLines: maxLines,
                  style: kilo.text.bodyLg,
                  decoration: InputDecoration(
                    hintText: hint,
                    counterText: '',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: kilo.space.s3,
                      vertical: kilo.space.s4,
                    ),
                    hintStyle: kilo.text.bodyLg.copyWith(
                      color: kilo.color.contentMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (error != null || helper != null) ...[
          SizedBox(height: kilo.space.s2),
          Text(
            error ?? helper!,
            style: kilo.text.bodySm.copyWith(
              color: invalid ? kilo.color.danger : kilo.color.contentSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
