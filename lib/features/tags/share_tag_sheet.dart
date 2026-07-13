import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/user_service.dart';
import '../../core/services/tag_service.dart';

/// Ouvre la feuille de partage d'un tag.
Future<void> showShareTagSheet(BuildContext context, TagModel tag) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ShareTagSheet(tag: tag),
  );
}

/// Partage d'un TAG : on génère un lien d'invitation et on l'envoie. Celui qui
/// le suit voit tous les souvenirs portant ce tag (présents et à venir) et peut
/// en ajouter — c'est le remplaçant du partage de carnet.
class ShareTagSheet extends StatefulWidget {
  final TagModel tag;

  const ShareTagSheet({super.key, required this.tag});

  @override
  State<ShareTagSheet> createState() => _ShareTagSheetState();
}

class _ShareTagSheetState extends State<ShareTagSheet> {
  bool _creatingLink = false;
  String? _error;
  ({String url, String downloadUrl, String title})? _inviteData;

  String? _copyFeedback;
  Timer? _copyFeedbackTimer;

  Map<String, _CollabInfo> _collabInfos = {};

  String get _shareMessage =>
      '📖 Rejoins mes souvenirs « ${_inviteData!.title} » sur Carnet :\n'
      '${_inviteData!.url}\n\n'
      'Pas encore l\'app ? Installe-la, puis rouvre le lien ci-dessus :\n'
      '${_inviteData!.downloadUrl}';

  @override
  void initState() {
    super.initState();
    _loadCollabInfos();
  }

  @override
  void dispose() {
    _copyFeedbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadCollabInfos() async {
    final uids = widget.tag.sharedWith;
    if (uids.isEmpty) return;
    final infos = <String, _CollabInfo>{};
    await Future.wait(uids.map((uid) async {
      final data = await UserService.getUserInfo(uid);
      infos[uid] = _CollabInfo(
        email: data?['email'] as String? ?? uid,
        displayName: data?['displayName'] as String? ?? '',
      );
    }));
    if (mounted) setState(() => _collabInfos = infos);
  }

  Future<void> _createInviteLink() async {
    setState(() {
      _creatingLink = true;
      _error = null;
    });
    try {
      final invite = await TagService.createInviteLink(widget.tag.id);
      if (!mounted) return;
      if (invite == null) {
        setState(() {
          _error = 'Création du lien impossible. Réessaie.';
          _creatingLink = false;
        });
        return;
      }
      setState(() {
        _inviteData = invite;
        _creatingLink = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Erreur : $e';
          _creatingLink = false;
        });
      }
    }
  }

  void _flashCopied(String message) {
    HapticFeedback.selectionClick();
    _copyFeedbackTimer?.cancel();
    setState(() => _copyFeedback = message);
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyFeedback = null);
    });
  }

  void _copyLink() {
    if (_inviteData == null) return;
    Clipboard.setData(ClipboardData(text: _inviteData!.url));
    _flashCopied('Lien copié ✓');
  }

  void _copyMessage() {
    if (_inviteData == null) return;
    Clipboard.setData(ClipboardData(text: _shareMessage));
    _flashCopied('Message copié ✓');
  }

  Future<void> _shareLink() async {
    if (_inviteData == null) return;
    await Share.share(_shareMessage,
        subject: 'Rejoins mes souvenirs « ${_inviteData!.title} »');
  }

  Future<void> _removeCollaborator(TagModel tag, String uid) async {
    await TagService.revoke(tag, uid: uid);
    if (mounted) setState(() => _collabInfos.remove(uid));
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser!.uid;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('tags')
          .doc(widget.tag.id)
          .snapshots(),
      builder: (context, snap) {
        final tag = snap.hasData && snap.data!.exists
            ? TagModel.fromFirestore(snap.data!)
            : widget.tag;
        final isOwner = tag.isOwner(currentUid);

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          decoration: const BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(children: [
                  const Icon(Icons.people_outline,
                      color: AppColors.sageDark, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Partager « ${tag.label} »',
                      style: const TextStyle(
                        fontFamily: 'Fraunces',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  isOwner
                      ? 'Qui suit ce lien voit tous les souvenirs tagués '
                          '« ${tag.label} » — y compris les prochains — et peut '
                          'en ajouter.'
                      : 'Ce tag t\'a été partagé : tu vois ses souvenirs et tu '
                          'peux en ajouter.',
                  style: const TextStyle(
                      color: AppColors.textMedium, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 18),
                if (isOwner) ...[
                  if (_inviteData == null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _creatingLink ? null : _createInviteLink,
                        icon: _creatingLink
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.link, size: 20),
                        label: Text(_creatingLink
                            ? 'Génération…'
                            : 'Générer le lien de partage'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        _inviteData!.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textDark),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copier le lien'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    if (_copyFeedback != null) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle,
                                color: AppColors.sage, size: 16),
                            const SizedBox(width: 6),
                            Text(_copyFeedback!,
                                style: const TextStyle(
                                    color: AppColors.sage,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _shareLink,
                            icon: const Icon(Icons.share, size: 16),
                            label: const Text('Partager'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.sageDark,
                              side: const BorderSide(color: AppColors.sageDark),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _copyMessage,
                            icon: const Icon(Icons.notes, size: 16),
                            label: const Text('Message'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textMedium,
                              side: const BorderSide(color: AppColors.border),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      const Icon(Icons.error_outline,
                          color: AppColors.error, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  color: AppColors.error, fontSize: 12))),
                    ]),
                  ],
                  const SizedBox(height: 18),
                ],
                if (tag.sharedWith.isNotEmpty) ...[
                  const _SectionLabel('Accès actifs'),
                  const SizedBox(height: 8),
                  ...tag.sharedWith.map((uid) {
                    final info = _collabInfos[uid];
                    final email = info?.email ?? uid;
                    final name = info?.displayName ?? '';
                    return _CollabTile(
                      avatar: email.isNotEmpty ? email[0].toUpperCase() : '?',
                      label: name.isNotEmpty ? name : email,
                      subtitle: name.isNotEmpty ? email : null,
                      onRemove:
                          isOwner ? () => _removeCollaborator(tag, uid) : null,
                    );
                  }),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.textMedium,
          letterSpacing: 1.2,
        ),
      );
}

class _CollabTile extends StatelessWidget {
  final String avatar;
  final String label;
  final String? subtitle;
  final VoidCallback? onRemove;

  const _CollabTile({
    required this.avatar,
    required this.label,
    this.subtitle,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.sageTint,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                avatar,
                style: const TextStyle(
                  color: AppColors.sageDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textDark,
                      fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(subtitle!,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMedium)),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline,
                  color: AppColors.error, size: 20),
              tooltip: 'Retirer l\'accès',
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

class _CollabInfo {
  final String email;
  final String displayName;
  const _CollabInfo({required this.email, required this.displayName});
}
