import 'package:flutter/material.dart';

import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';

/// Shared login/register form. On success, stores the session and pops.
class _AuthForm extends StatefulWidget {
  const _AuthForm({
    required this.repository,
    required this.isRegister,
  });

  final StockRepository repository;
  final bool isRegister;

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final auth = AuthScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text;
      final res = widget.isRegister
          ? await widget.repository.register(email, password)
          : await widget.repository.login(email, password);
      await auth.setSession(res.accessToken, res.user);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong. $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cta = widget.isRegister ? 'Create account' : 'Log in';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    key: const Key('auth_error'),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              TextFormField(
                key: const Key('email_field'),
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty || !t.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('password_field'),
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final t = v ?? '';
                  if (widget.isRegister && t.length < 8) {
                    return 'Use at least 8 characters';
                  }
                  if (t.isEmpty) return 'Enter your password';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('submit_button'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(cta),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.repository});
  final StockRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log in')),
      body: SafeArea(
        child: _AuthForm(repository: repository, isRegister: false),
      ),
    );
  }
}

class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key, required this.repository});
  final StockRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: _AuthForm(repository: repository, isRegister: true),
      ),
    );
  }
}
