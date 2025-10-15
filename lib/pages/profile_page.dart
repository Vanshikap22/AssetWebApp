// lib/pages/profile_page.dart
import 'package:flutter/material.dart';
import '../services/auth_service.dart'; // getSavedAuth / clearSavedAuth
import '../services/prefs.dart';       // saveAuth (wraps SharedPreferences)

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _editing = false;
  bool _loading = true;

  // Controllers (prefilled from saved login JSON)
  final _name  = TextEditingController();
  final _email = TextEditingController();
  final _role  = TextEditingController();  // not returned by API; local only
  final _phone = TextEditingController();
  final _org   = TextEditingController();  // not returned by API; local only

  @override
  void initState() {
    super.initState();
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final auth = await AuthService.getSavedAuth();
    // Expected keys from your login response:
    // username, email, phonenumber, accessToken, refreshToken, id, message
    _name.text  = (auth?['username'] ?? '').toString();
    _email.text = (auth?['email'] ?? '').toString();
    _phone.text = (auth?['phonenumber'] ?? '').toString();

    // Optional locals (since backend doesn’t provide them yet)
    _role.text = _role.text.isEmpty ? 'User' : _role.text;
    _org.text  = _org.text.isEmpty ? '' : _org.text;

    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _role.dispose();
    _phone.dispose();
    _org.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: cs.primaryContainer,
                  child: const Icon(Icons.person, size: 44),
                ),
                if (_editing)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Material(
                      color: cs.primary,
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Avatar update coming soon…')),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Profile',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(height: 16),

          _profileField('Full Name', _name, enabled: _editing, keyboardType: TextInputType.name),
          const SizedBox(height: 12),
          _profileField('Email', _email, enabled: _editing, keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 12),
          _profileField('Role', _role, enabled: _editing),
          const SizedBox(height: 12),
          _profileField('Phone', _phone, enabled: _editing, keyboardType: TextInputType.phone),
          const SizedBox(height: 12),
          _profileField('Organization', _org, enabled: _editing),
          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    setState(() => _editing = !_editing);

                    if (!_editing) {
                      // Save local edits back to the same saved auth JSON.
                      final saved = await AuthService.getSavedAuth() ?? {};
                      saved['username']     = _name.text;
                      saved['email']        = _email.text;
                      saved['phonenumber']  = _phone.text;
                      // Optionally persist local-only fields:
                      // saved['role']         = _role.text;
                      // saved['organization'] = _org.text;

                      await Prefs.saveAuth(saved);

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Profile saved')),
                        );
                      }
                    }
                  },
                  icon: Icon(_editing ? Icons.check : Icons.edit),
                  label: Text(_editing ? 'Save' : 'Edit'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 12),

          Text(
            'Account',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  onTap: () async {
                    await AuthService.clearSavedAuth();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Signed out')),
                    );
                    Navigator.pop(context); // or pushReplacement to Login page
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileField(
    String label,
    TextEditingController c, {
    bool enabled = false,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: c,
      enabled: enabled,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: enabled ? const Icon(Icons.edit_outlined) : null,
      ),
    );
  }
}
