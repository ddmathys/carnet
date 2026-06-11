import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/services/user_service.dart';
import '../../core/services/resend_service.dart';
import '../../core/config/app_config.dart';

class ShareNotebookSheet extends StatefulWidget {
  final NotebookModel notebook;

  const ShareNotebookSheet({super.key, required this.notebook});

  @override
  State<ShareNotebookSheet> createState() => _ShareNotebookSheetState();
}

class _ShareNotebookSheetState extends State<ShareNotebookSheet> {
  final _emailCtrl = TextEditingController();
  bool _inviting = false;
  String? _inviteError;
  String? _inviteSuccess;

  final _resend = ResendService(apiKey: AppConfig.resendApiKey);

  // uid → {email, displayName}
  Map<String, _CollabInfo> _collabInfos = {};

  @override
  void initState() {
    super.initState();
    _loadCollabInfos();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCollabInfos() async {
    final uids = widget.notebook.sharedWith;
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

  Future<void> _invite() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _inviteError = 'Email invalide');
      return;
    }
    final currentUid = FirebaseAuth.instance.currentUser!.uid;
    if (email == FirebaseAuth.instance.currentUser!.email?.toLowerCase()) {
      setState(() => _inviteError = 'C\'est ton propre email !');
      return;
    }

    setState(() { _inviting = true; _inviteError = null; _inviteSuccess = null; });

    try {
      // Check if email already invited/added
      final already = widget.notebook.invitedEmails.contains(email);
      if (already) {
        setState(() { _inviteError = 'Invitation déjà envoyée à cet email.'; _inviting = false; });
        return;
      }

      // Try to find existing user
      final uid = await UserService.findUidByEmail(email);

      if (uid != null) {
        if (uid == currentUid) {
          setState(() { _inviteError = 'C\'est ton propre compte !'; _inviting = false; });
          return;
        }
        if (widget.notebook.sharedWith.contains(uid)) {
          setState(() { _inviteError = 'Cette personne a déjà accès au carnet.'; _inviting = false; });
          return;
        }
        // Add directly to sharedWith
        await FirebaseFirestore.instance
            .collection('notebooks')
            .doc(widget.notebook.id)
            .update({'sharedWith': FieldValue.arrayUnion([uid])});
        _emailCtrl.clear();
        await _resend.sendNotebookInvitation(
          toEmail: email,
          notebookTitle: widget.notebook.title,
          inviterEmail: FirebaseAuth.instance.currentUser!.email ?? '',
          downloadUrl: AppConfig.appDownloadUrl,
        );
        setState(() { _inviteSuccess = '$email a été ajouté au carnet.'; _inviting = false; });
        await _loadCollabInfos();
      } else {
        // User not found — add to pending invites
        await FirebaseFirestore.instance
            .collection('notebooks')
            .doc(widget.notebook.id)
            .update({'invitedEmails': FieldValue.arrayUnion([email])});
        _emailCtrl.clear();
        await _resend.sendNotebookInvitation(
          toEmail: email,
          notebookTitle: widget.notebook.title,
          inviterEmail: FirebaseAuth.instance.currentUser!.email ?? '',
          downloadUrl: AppConfig.appDownloadUrl,
        );
        setState(() {
          _inviteSuccess = 'Invitation envoyée à $email.';
          _inviting = false;
        });
      }
    } catch (e) {
      setState(() { _inviteError = 'Erreur : $e'; _inviting = false; });
    }
  }

  Future<void> _removeCollaborator(String uid) async {
    await FirebaseFirestore.instance
        .collection('notebooks')
        .doc(widget.notebook.id)
        .update({'sharedWith': FieldValue.arrayRemove([uid])});
    setState(() {
      _collabInfos.remove(uid);
      _inviteSuccess = 'Accès retiré.';
    });
  }

  Future<void> _removePendingInvite(String email) async {
    await FirebaseFirestore.instance
        .collection('notebooks')
        .doc(widget.notebook.id)
        .update({'invitedEmails': FieldValue.arrayRemove([email])});
    setState(() => _inviteSuccess = 'Invitation annulée.');
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser!.uid;
    final isOwner = widget.notebook.isOwner(currentUid);

    // Live data: re-read from Firestore stream for up-to-date lists
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('notebooks')
          .doc(widget.notebook.id)
          .snapshots(),
      builder: (context, snap) {
        final nb = snap.hasData && snap.data!.exists
            ? NotebookModel.fromFirestore(snap.data!)
            : widget.notebook;

        return Container(
          decoration: const BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
              24, 12, 24, MediaQuery.of(context).padding.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title
              Row(children: [
                const Icon(Icons.people_outline, color: AppColors.sageDark, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Partager « ${nb.title} »',
                  style: const TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                isOwner
                    ? 'Invite des personnes à accéder à ce carnet.'
                    : 'Tu as accès à ce carnet en tant que collaborateur.',
                style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
              ),
              const SizedBox(height: 18),

              // ── Active collaborators ─────────────────────────────────────
              if (nb.sharedWith.isNotEmpty) ...[
                const _SectionLabel('Accès actifs'),
                const SizedBox(height: 8),
                ...nb.sharedWith.map((uid) {
                  final info = _collabInfos[uid];
                  final email = info?.email ?? uid;
                  final name = info?.displayName ?? '';
                  return _CollabTile(
                    avatar: email.isNotEmpty ? email[0].toUpperCase() : '?',
                    label: name.isNotEmpty ? name : email,
                    subtitle: name.isNotEmpty ? email : null,
                    badge: null,
                    onRemove: isOwner ? () => _removeCollaborator(uid) : null,
                  );
                }),
                const SizedBox(height: 12),
              ],

              // ── Pending invites ──────────────────────────────────────────
              if (nb.invitedEmails.isNotEmpty) ...[
                const _SectionLabel('Invitations en attente'),
                const SizedBox(height: 8),
                ...nb.invitedEmails.map((email) => _CollabTile(
                  avatar: email[0].toUpperCase(),
                  label: email,
                  subtitle: 'Pas encore inscrit(e)',
                  badge: 'En attente',
                  onRemove: isOwner ? () => _removePendingInvite(email) : null,
                )),
                const SizedBox(height: 12),
              ],

              // No collaborators
              if (nb.sharedWith.isEmpty && nb.invitedEmails.isEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(children: [
                    Icon(Icons.lock_outline, color: AppColors.textMedium, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Ce carnet est privé pour l\'instant. Invite quelqu\'un pour collaborer.',
                        style: TextStyle(color: AppColors.textMedium, fontSize: 13, height: 1.4),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
              ],

              // ── Invite form (owner only) ──────────────────────────────────
              if (isOwner) ...[
                const _SectionLabel('Inviter quelqu\'un'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          hintText: 'Email de la personne…',
                          hintStyle: const TextStyle(color: AppColors.softGray, fontSize: 14),
                          filled: true,
                          fillColor: AppColors.background,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: AppColors.sageDark, width: 1.5),
                          ),
                        ),
                        onFieldSubmitted: (_) => _invite(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _inviting
                        ? const SizedBox(
                            width: 48, height: 48,
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                        : ElevatedButton(
                            onPressed: _invite,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text('Inviter'),
                          ),
                  ],
                ),

                // Feedback messages
                if (_inviteError != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.error_outline, color: AppColors.error, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_inviteError!, style: const TextStyle(color: AppColors.error, fontSize: 12))),
                  ]),
                ],
                if (_inviteSuccess != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.check_circle_outline, color: AppColors.sage, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_inviteSuccess!, style: const TextStyle(color: AppColors.sage, fontSize: 12))),
                  ]),
                ],
                const SizedBox(height: 6),
                Text(
                  'La personne recevra l\'accès immédiatement si elle a déjà un compte, sinon dès sa première connexion.',
                  style: TextStyle(color: AppColors.textMedium.withOpacity(0.7), fontSize: 11, height: 1.4),
                ),
              ],
            ],
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
  final String? badge;
  final VoidCallback? onRemove;

  const _CollabTile({
    required this.avatar,
    required this.label,
    this.subtitle,
    this.badge,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // Avatar circle
          Container(
            width: 38, height: 38,
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
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(fontSize: 13, color: AppColors.textDark, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badge != null)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.amber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(badge!, style: const TextStyle(fontSize: 10, color: AppColors.amber, fontWeight: FontWeight.w600)),
                    ),
                ]),
                if (subtitle != null)
                  Text(subtitle!, style: const TextStyle(fontSize: 11, color: AppColors.textMedium)),
              ],
            ),
          ),
          // Remove button
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.remove_circle_outline, color: AppColors.error, size: 20),
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
