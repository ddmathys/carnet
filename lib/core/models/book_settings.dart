class BookSettings {
  final String detail;          // 'brief' | 'balanced' | 'detailed'
  final String tone;            // 'poetic' | 'intimate' | 'narrative'
  final bool locationComments;  // Show AI location description below memory description

  const BookSettings({
    this.detail = 'balanced',
    this.tone = 'poetic',
    this.locationComments = false,
  });

  BookSettings copyWith({String? detail, String? tone, bool? locationComments}) =>
      BookSettings(
        detail: detail ?? this.detail,
        tone: tone ?? this.tone,
        locationComments: locationComments ?? this.locationComments,
      );

  Map<String, dynamic> toMap() => {
        'detail': detail,
        'tone': tone,
        'locationComments': locationComments,
      };

  factory BookSettings.fromMap(Map<String, dynamic> map) => BookSettings(
        detail: (map['detail'] as String?) ?? 'balanced',
        tone: (map['tone'] as String?) ?? 'poetic',
        locationComments: (map['locationComments'] as bool?) ?? false,
      );
}
