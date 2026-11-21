import 'package:flutter/material.dart';

/// The Cwhale whale mark used wherever the app needs its own visual identity.
class CwhaleBrandMark extends StatelessWidget {
  const CwhaleBrandMark({
    super.key,
    required this.size,
    required this.cornerRadius,
  });

  final double size;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(cornerRadius),
    child: SizedBox.square(
      dimension: size,
      child: Image.asset(
        'design/CWhale-icon-centered.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      ),
    ),
  );
}
