import 'package:dtrsync/features/auth/data/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AuthState {
  final bool isLogin;
  final bool isLoading;
  final bool obscurePassword;
  final String? errorMessage;

  const AuthState({
    this.isLogin = true,
    this.isLoading = false,
    this.obscurePassword = true,
    this.errorMessage,
  });

  AuthState copyWith({
    bool? isLogin,
    bool? isLoading,
    bool? obscurePassword,
    String? errorMessage,
  }) {
    return AuthState(
      isLogin: isLogin ?? this.isLogin,
      isLoading: isLoading ?? this.isLoading,
      obscurePassword: obscurePassword ?? this.obscurePassword,
      errorMessage: errorMessage,
    );
  }
}

class AuthNotifier extends Notifier<AuthState> {
  final AuthRepository _repository = AuthRepository();

  @override
  AuthState build() => const AuthState();

  void toggleAuthMode() {
    state = state.copyWith(isLogin: !state.isLogin, errorMessage: null);
  }

  void togglePasswordVisibility() {
    state = state.copyWith(obscurePassword: !state.obscurePassword);
  }

  // Changed to Map<String, dynamic> to match the repository payload
  Future<Map<String, dynamic>?> submit(Map<String, dynamic> payload) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final userData = await _repository.login(payload);
      state = state.copyWith(isLoading: false);
      return userData;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return null;
    }
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);