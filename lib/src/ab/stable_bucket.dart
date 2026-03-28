import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Deterministic bucket index for A/B — see [docs/hash-bucketing-and-cache.md].
///
/// Do not use [Object.hashCode] or [String.hashCode] for experiments.
int stableBucketIndex({
  required String userId,
  required String experimentKey,
  String? experimentRevision,
  required int bucketCount,
}) {
  if (bucketCount < 2) {
    throw ArgumentError.value(bucketCount, 'bucketCount', 'must be >= 2');
  }
  final parts = [userId, experimentKey];
  if (experimentRevision != null && experimentRevision.isNotEmpty) {
    parts.add(experimentRevision);
  }
  final input = parts.join('\x00');
  final digest = md5.convert(utf8.encode(input)).bytes;
  var acc = BigInt.zero;
  for (var i = 0; i < 8 && i < digest.length; i++) {
    acc = (acc << 8) + BigInt.from(digest[i]);
  }
  return (acc % BigInt.from(bucketCount)).toInt();
}
