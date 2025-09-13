// lib/main.dart - UPDATED WITH VERSION GUARD
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';

// Import modularized components
import 'package:canteen_app/config/theme_config.dart';
import 'package:canteen_app/config/route_config.dart';
import 'package:canteen_app/screens/splash/splash_screen.dart';
import 'package:canteen_app/services/notification_service.dart';
import 'package:canteen_app/utils/firebase_utils.dart';
import 'package:canteen_app/services/auth_service.dart';
import 'package:canteen_app/providers/cart_provider.dart';
import 'package:canteen_app/widgets/version_guard.dart';

// Initialize global plugins
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = 
    FlutterLocalNotificationsPlugin();

// Navigation key for accessing navigator from anywhere
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Auth service for global access
final AuthService authService = AuthService();

Future<void> main() async {
  // Ensure widgets are initialized
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF004D40),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  
  // Initialize Firebase based on platform
  await _initializeFirebase();
  
  // Run the application with version checking
  runApp(
    VersionGuard(
      child: const ThintavaApp(),
    ),
  );
}

// Firebase initialization function
Future<void> _initializeFirebase() async {
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: "AIzaSyCUIhov47JaVreRYYxgrCPQFkF0UhHkmlk",
          authDomain: "thintava2.firebaseapp.com",
          projectId: "thintava2",
          storageBucket: "thintava2.firebasestorage.app",
          messagingSenderId: "429051439107",
          appId: "1:429051439107:android:b31f0938cbae63d5f34636",
          measurementId: "",
        ),
      );
      await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
    } else {
      await Firebase.initializeApp();
      
      // Initialize FCM more safely
      try {
        await _initializeFCMSafely();
      } catch (e) {
        print('⚠️ FCM initialization failed: $e');
        // Continue without FCM if it fails
      }
    }
    print('✅ Firebase initialized successfully');
  } catch (e) {
    print('❌ Firebase initialization error: $e');
    rethrow;
  }
}

// Safe FCM initialization
Future<void> _initializeFCMSafely() async {
  try {
    // Request permission first
    final messaging = FirebaseMessaging.instance;
    
    await messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );
    
    // Only get token after permission is granted
    final token = await messaging.getToken();
    if (token != null) {
      print('✅ FCM Token obtained: ${token.substring(0, 20)}...');
    } else {
      print('⚠️ FCM Token is null');
    }
    
    await NotificationService.initializeNotifications();
  } catch (e) {
    print('❌ FCM initialization error: $e');
    throw e;
  }
}

// Updated saveInitialFCMToken function
Future<void> saveInitialFCMToken() async {
  try {
    // Add delay to ensure Firebase is fully initialized
    await Future.delayed(const Duration(milliseconds: 500));
    
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final messaging = FirebaseMessaging.instance;
      
      // Check if messaging is available
      try {
        final token = await messaging.getToken();
        
        if (token != null && token.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .update({
            'fcmToken': token,
            'tokenUpdatedAt': FieldValue.serverTimestamp(),
          });
          print('✅ Initial FCM token saved successfully');
        } else {
          print('⚠️ FCM token is null or empty');
        }
      } catch (tokenError) {
        print('❌ Error getting FCM token: $tokenError');
        // Don't save if token retrieval fails
      }
    } else {
      print('⚠️ No authenticated user found for FCM token save');
    }
  } catch (e) {
    print('❌ Error in saveInitialFCMToken: $e');
    // Don't throw - this is not critical for app functionality
  }
}

class ThintavaApp extends StatefulWidget {
  const ThintavaApp({super.key});
  
  @override
  State<ThintavaApp> createState() => _ThintavaAppState();
}

class _ThintavaAppState extends State<ThintavaApp> {
  final _appLoadingFuture = Future.delayed(const Duration(milliseconds: 500));
  
  @override
  void initState() {
    super.initState();
    
    // DEVICE MANAGEMENT - ENABLED SESSION LISTENER
    authService.startSessionListener(() {
      // This will be called if the user is logged out on another device
      _handleForcedLogout();
    });
    
    print('🚀 Thintava App initialized with Device Management and Version Control');
  }
  
  // FIXED: DEVICE MANAGEMENT - ENHANCED FORCED LOGOUT HANDLER
  void _handleForcedLogout() {
    print('🚫 Device session terminated - handling forced logout');
    
    // Check if we're currently showing a dialog to avoid stacking dialogs
    if (ModalRoute.of(navigatorKey.currentContext!)?.isCurrent != true) {
      print('⚠️ Modal route not current, skipping forced logout dialog');
      return;
    }
    
    // Clean up cart
    try {
      if (navigatorKey.currentContext != null) {
        final cartProvider = Provider.of<CartProvider>(navigatorKey.currentContext!, listen: false);
        cartProvider.cleanup();
        print('✅ Cart cleaned up');
      }
    } catch (e) {
      print('⚠️ Error cleaning up cart during forced logout: $e');
    }
    
    // Show notification dialog ONLY if app is in foreground and context is available
    if (navigatorKey.currentContext != null && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      // Add a small delay to ensure the UI is ready
      Future.delayed(const Duration(milliseconds: 300), () {
        if (navigatorKey.currentContext != null) {
          _showForcedLogoutDialog();
        }
      });
    } else {
      // If app is not in foreground, just navigate to auth screen
      print('📱 App not in foreground, navigating to auth without dialog');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigatorKey.currentContext != null) {
          Navigator.pushNamedAndRemoveUntil(
            navigatorKey.currentContext!,
            '/auth',
            (route) => false,
          );
        }
      });
    }
  }
  
  // ADDED: Separate method for showing forced logout dialog
  void _showForcedLogoutDialog() {
    // Check if a dialog is already showing
    if (ModalRoute.of(navigatorKey.currentContext!)?.settings.name == 'forced_logout_dialog') {
      print('⚠️ Forced logout dialog already showing, skipping');
      return;
    }
    
    showDialog(
      context: navigatorKey.currentContext!,
      barrierDismissible: false,
      routeSettings: const RouteSettings(name: 'forced_logout_dialog'), // Add route name
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.devices_other,
                color: Colors.red,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'New Device Login Detected', 
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your account has been logged in on another device.',
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'For security reasons, you have been automatically logged out from this device.',
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Only one device can be logged in at a time for security.',
                      style: GoogleFonts.poppins(
                        fontSize: 12,
                        color: Colors.blue[700],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.pushNamedAndRemoveUntil(context, '/auth', (route) => false);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFB703),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            icon: const Icon(Icons.login, size: 18),
            label: Text(
              'Sign In Again',
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    // DEVICE MANAGEMENT - CLEANUP SESSION LISTENER
    authService.stopSessionListener();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _appLoadingFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFB703), Color(0xFFFFB703)],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo Container with shadow effect
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/icon/app_icon.png',
                          width: 60,
                          height: 60,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Thintava',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 32),
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        strokeWidth: 3,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Loading...',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        
        // WRAP YOUR MATERIALAPP WITH CHANGENOTIFIERPROVIDER
        return ChangeNotifierProvider(
          create: (context) => CartProvider()..loadFromStorage(), // Load cart on app start
          child: MaterialApp(
            title: 'Thintava - Smart Food Ordering with Version Control',
            debugShowCheckedModeBanner: false,
            theme: _buildAppTheme(),
            navigatorKey: navigatorKey,
            home: const SplashScreen(),
            routes: RouteConfig.routes,
            builder: (context, child) {
              return MediaQuery(
                // Apply font scaling factor
                data: MediaQuery.of(context).copyWith(textScaleFactor: 1.0),
                child: child!,
              );
            },
          ),
        );
      },
    );
  }
  
  ThemeData _buildAppTheme() {
    final baseTheme = ThemeConfig.lightTheme;
    
    return baseTheme.copyWith(
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      splashColor: const Color(0xFFFFB703).withOpacity(0.3),
      highlightColor: const Color(0xFFFFB703).withOpacity(0.1),
      colorScheme: baseTheme.colorScheme.copyWith(
        primary: const Color(0xFFFFB703),
        secondary: const Color(0xFF004D40),
        surface: Colors.white,
        background: const Color(0xFFF5F5F5),
        error: Colors.redAccent,
        onPrimary: Colors.black,
        onSecondary: Colors.white,
        onSurface: Colors.black87,
        onBackground: Colors.black54,
        onError: Colors.white,
        brightness: Brightness.light,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(baseTheme.textTheme).copyWith(
        displayLarge: GoogleFonts.poppins(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
        displayMedium: GoogleFonts.poppins(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        displaySmall: GoogleFonts.poppins(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        headlineMedium: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        headlineSmall: GoogleFonts.poppins(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        titleLarge: GoogleFonts.poppins(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
        bodyLarge: GoogleFonts.poppins(
          fontSize: 16,
          color: Colors.black87,
        ),
        bodyMedium: GoogleFonts.poppins(
          fontSize: 14,
          color: Colors.black87,
        ),
        labelLarge: GoogleFonts.poppins(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 4,
          backgroundColor: const Color(0xFFFFB703),
          foregroundColor: Colors.black87,
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 16,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF004D40),
          side: const BorderSide(color: Color(0xFF004D40), width: 1.5),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 16,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF004D40),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: GoogleFonts.poppins(color: Colors.black54),
        hintStyle: GoogleFonts.poppins(color: Colors.black38),
        errorStyle: GoogleFonts.poppins(color: Colors.redAccent),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFFB703), width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.redAccent, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF004D40),
        contentTextStyle: GoogleFonts.poppins(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
        contentTextStyle: GoogleFonts.poppins(
          fontSize: 16,
          color: Colors.black87,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: Colors.white,
      ),
      // FIXED: Changed AppBarThemeData to AppBarTheme
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF004D40),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: Color(0xFFFFB703),
        unselectedItemColor: Colors.black54,
        selectedIconTheme: IconThemeData(size: 28),
        unselectedIconTheme: IconThemeData(size: 24),
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.grey.shade200,
        disabledColor: Colors.grey.shade300,
        selectedColor: const Color(0xFFFFB703),
        secondarySelectedColor: const Color(0xFF004D40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        labelStyle: GoogleFonts.poppins(fontSize: 14, color: Colors.black87),
        secondaryLabelStyle: GoogleFonts.poppins(fontSize: 14, color: Colors.white),
        brightness: Brightness.light,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: GoogleFonts.poppins(color: Colors.white, fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}

/// Global navigation methods for use anywhere in the app
class NavigationUtils {
  static void navigateTo(BuildContext context, String routeName, {Object? arguments}) {
    Navigator.of(context).pushNamed(routeName, arguments: arguments);
  }
  
  static void navigateToReplacement(BuildContext context, String routeName, {Object? arguments}) {
    Navigator.of(context).pushReplacementNamed(routeName, arguments: arguments);
  }
  
  static void navigateToAndClearStack(BuildContext context, String routeName, {Object? arguments}) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      routeName, 
      (route) => false,
      arguments: arguments
    );
  }
  
  static void goBack(BuildContext context) {
    Navigator.of(context).pop();
  }
  
  /// For use with the global navigator key when context is not available
  static void globalNavigateTo(String routeName, {Object? arguments}) {
    navigatorKey.currentState?.pushNamed(routeName, arguments: arguments);
  }
}