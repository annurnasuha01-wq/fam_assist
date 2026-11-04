import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/create_folder_screen.dart';
import 'services/folder_service.dart';
import 'services/notification_scheduler.dart';

/// true  -> every time the app is started it opens the LOGIN screen first.
///          The saved session is NOT signed out (so a guest's tasks are never
///          orphaned); "Use without login" simply resumes the same guest.
/// false -> old behaviour: a remembered login/guest goes straight to the
///          Dashboard.
const bool kAlwaysStartAtLogin = true;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw the first frame right away. Firebase etc. start inside _Bootstrap
  // while the user already sees the Fam-Assist splash (no long black screen).
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Fam-Assist',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<Widget> _init = _start();

  Future<Widget> _start() async {
    // Firebase must be ready before anything else uses it.
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Notifications (timezone data + permission prompt) are NOT needed to
    // show the first page, so they run in the background.
    unawaited(
      NotificationScheduler.init().catchError((Object e) {
        debugPrint('NotificationScheduler.init failed: $e');
      }),
    );

    // Always begin at the Login screen (see kAlwaysStartAtLogin).
    if (kAlwaysStartAtLogin) return const LoginScreen();

    return _decideHome();
  }

  Future<Widget> _decideHome() async {
    User? user;
    try {
      // The saved session is restored asynchronously right after start-up.
      user = await FirebaseAuth.instance.authStateChanges().first.timeout(
        const Duration(seconds: 4),
      );
    } catch (_) {
      user = FirebaseAuth.instance.currentUser;
    }

    if (user == null) return const LoginScreen();

    var hasFolder = true; // if the check fails (offline), open the Dashboard
    try {
      hasFolder = await FolderService.userHasFolders();
    } catch (e) {
      debugPrint('userHasFolders failed: $e');
    }
    return hasFolder
        ? const DashboardScreen()
        : const CreateFolderScreen(isOnboarding: true);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _init,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            snapshot.hasData) {
          return snapshot.data!;
        }
        if (snapshot.hasError) {
          return _splash(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Could not start the app.\nCheck your internet connection.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => setState(() => _init = _start()),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        return _splash(
          child: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2.5,
            ),
          ),
        );
      },
    );
  }

  Widget _splash({required Widget child}) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/bg.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo.png', width: 180, height: 180),
            const SizedBox(height: 24),
            child,
          ],
        ),
      ),
    );
  }
}
