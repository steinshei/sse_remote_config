/// JSON shape aligned with [docs/api-contract-v1.md] §5.
class ExperimentDefinition {
  const ExperimentDefinition({
    required this.key,
    required this.bucketCount,
    required this.variants,
    this.revision,
  });

  final String key;
  final int bucketCount;

  /// Keys are bucket indices as strings (`"0"` … `"n-1"`).
  final Map<String, Map<String, dynamic>> variants;

  /// Optional; included in stable bucket input when non-null.
  final String? revision;

  factory ExperimentDefinition.fromJson(Map<String, dynamic> json) {
    final rawVariants = json['variants'];
    final variants = <String, Map<String, dynamic>>{};
    if (rawVariants is Map) {
      for (final entry in rawVariants.entries) {
        final v = entry.value;
        if (v is Map) {
          variants['${entry.key}'] = Map<String, dynamic>.from(
            v.map((k, dynamic val) => MapEntry(k.toString(), val)),
          );
        }
      }
    }
    return ExperimentDefinition(
      key: json['key'] as String,
      bucketCount: json['bucket_count'] as int,
      variants: variants,
      revision: json['experiment_revision'] as String? ?? json['revision'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final v = <String, dynamic>{
      'key': key,
      'bucket_count': bucketCount,
      'variants': variants,
    };
    final r = revision;
    if (r != null) {
      v['experiment_revision'] = r;
    }
    return v;
  }
}

class ConfigBundle {
  const ConfigBundle({
    required this.version,
    required this.data,
    this.conditions,
    this.meta,
    this.experiments,
  });

  final int version;
  final Map<String, dynamic> data;
  final Map<String, dynamic>? conditions;

  /// API field `_meta`; exposed as [meta] in Dart.
  final Map<String, dynamic>? meta;
  final List<ExperimentDefinition>? experiments;

  factory ConfigBundle.fromJson(Map<String, dynamic> json) {
    final experimentsJson = json['experiments'];
    return ConfigBundle(
      version: json['version'] as int,
      data: Map<String, dynamic>.from(json['data'] as Map? ?? const {}),
      conditions: (json['conditions'] as Map?)?.cast<String, dynamic>(),
      meta: (json['_meta'] as Map?)?.cast<String, dynamic>(),
      experiments: experimentsJson is List
          ? experimentsJson
              .map((e) => ExperimentDefinition.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'data': data,
      if (conditions != null) 'conditions': conditions,
      if (meta != null) '_meta': meta,
      if (experiments != null) 'experiments': experiments!.map((e) => e.toJson()).toList(),
    };
  }

  /// Returns a copy with [data] replaced (experiments already applied).
  ConfigBundle copyWithMergedData(Map<String, dynamic> mergedData) {
    return ConfigBundle(
      version: version,
      data: mergedData,
      conditions: conditions,
      meta: meta,
      experiments: experiments,
    );
  }
}
