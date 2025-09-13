// lib/presentation/widgets/cart/cart_payment_handler.dart - UPDATED WITH PLATFORM FEE
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:canteen_app/providers/cart_provider.dart';
import 'package:canteen_app/services/active_order_service.dart';
import 'package:canteen_app/services/reservation_service.dart';
import 'package:canteen_app/models/reservation_model.dart';
import 'package:canteen_app/presentation/widgets/cart/cart_dialogs.dart';
import 'package:canteen_app/utils/platform_fee_calculator.dart';  // ✅ NEW IMPORT

class CartPaymentHandler {
  final BuildContext context;
  final Map<String, dynamic> menuMap;
  final double total;  // ✅ This now includes platform fee
  late Razorpay _razorpay;
  
  String? currentRazorpayOrderId;
  Reservation? currentReservation;
  bool _isProcessing = false;

  CartPaymentHandler({
    required this.context,
    required this.menuMap,
    required this.total,  // ✅ Total already includes platform fee
  }) {
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  void dispose() {
    _razorpay.clear();
  }

  /// Check network connectivity before starting payment
  Future<bool> _checkNetworkConnectivity() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      
      if (connectivityResult == ConnectivityResult.none) {
        _showErrorSnackBar(
          "No internet connection available",
          "Please check your network settings and try again",
          Icons.wifi_off,
          action: SnackBarAction(
            label: 'Settings',
            textColor: Colors.white,
            onPressed: () {
              // You can add logic to open network settings
            },
          ),
        );
        return false;
      }
      
      if (connectivityResult == ConnectivityResult.mobile) {
        _showInfoSnackBar(
          "Using mobile data",
          "Payment may take longer on slow connections",
          Icons.signal_cellular_alt,
        );
      }
      
      return true;
    } catch (e) {
      print('❌ Error checking connectivity: $e');
      return true; // Assume connected if check fails
    }
  }

  /// ✅ UPDATED: Create Razorpay Order with total including platform fee
  Future<String?> _createRazorpayOrder(double amount) async {
    int retryCount = 0;
    const maxRetries = 3;
    const baseDelay = Duration(seconds: 2);

    while (retryCount < maxRetries) {
      try {
        print('🔄 Creating Razorpay order (attempt ${retryCount + 1}/$maxRetries) for amount: ₹$amount (includes platform fee)');
        
        final callable = FirebaseFunctions.instance.httpsCallable('createRazorpayOrder');
        
        // Add timeout to prevent hanging on slow networks
        final result = await callable.call({
          'amount': (amount * 100).toInt(),  // ✅ Amount already includes platform fee
          'currency': 'INR',
          'receipt': 'order_${DateTime.now().millisecondsSinceEpoch}',
          'notes': {
            'app': 'Thintava',
            'order_type': 'food_order',
            'includes_platform_fee': 'true',  // ✅ NEW: Mark that this includes platform fee
          }
        }).timeout(
          const Duration(seconds: 45), // 45 second timeout
          onTimeout: () {
            throw Exception('NETWORK_TIMEOUT');
          },
        );

        print('🔍 Firebase Function response: ${result.data}');

        if (result.data != null && result.data['success'] == true) {
          String? orderId;
          if (result.data['orderId'] != null) {
            orderId = result.data['orderId'];
          } else if (result.data['order'] != null && result.data['order']['id'] != null) {
            orderId = result.data['order']['id'];
          }
          
          if (orderId != null) {
            print('✅ Firebase Function created Razorpay order: $orderId (with platform fee)');
            return orderId;
          } else {
            throw Exception('ORDER_ID_MISSING');
          }
        } else {
          throw Exception('ORDER_CREATION_FAILED');
        }
      } on FirebaseFunctionsException catch (e) {
        print('❌ Firebase Functions Error (attempt ${retryCount + 1}): ${e.code} - ${e.message}');
        
        // Don't retry authentication or configuration errors
        if (e.code == 'unauthenticated' || e.code == 'failed-precondition') {
          throw Exception('AUTH_ERROR:${e.message}');
        }
        
        if (e.code == 'internal' && retryCount < maxRetries - 1) {
          retryCount++;
          final delay = baseDelay * (retryCount * retryCount);
          print('⏳ Retrying in ${delay.inSeconds} seconds...');
          await Future.delayed(delay);
          continue;
        }
        
        throw Exception('FIREBASE_ERROR:${e.message}');
        
      } catch (e) {
        print('❌ General error (attempt ${retryCount + 1}): $e');
        
        // Handle specific error types
        if (e.toString().contains('NETWORK_TIMEOUT')) {
          retryCount++;
          if (retryCount >= maxRetries) {
            throw Exception('NETWORK_TIMEOUT');
          }
          
          final delay = baseDelay * (retryCount * retryCount);
          print('⏳ Network timeout, retrying in ${delay.inSeconds} seconds...');
          await Future.delayed(delay);
          continue;
        }
        
        // For other network-related errors, retry
        if (e.toString().contains('network') || 
            e.toString().contains('timeout') || 
            e.toString().contains('connection')) {
          retryCount++;
          if (retryCount >= maxRetries) {
            throw Exception('NETWORK_ERROR');
          }
          
          final delay = baseDelay * (retryCount * retryCount);
          print('⏳ Network error, retrying in ${delay.inSeconds} seconds...');
          await Future.delayed(delay);
          continue;
        }
        
        // Non-network errors shouldn't be retried
        throw Exception('GENERAL_ERROR:$e');
      }
    }
    
    throw Exception('MAX_RETRIES_EXCEEDED');
  }

  /// ✅ UPDATED: Start payment with comprehensive error handling (total includes platform fee)
  Future<void> startPayment() async {
    if (_isProcessing) {
      _showInfoSnackBar(
        "Payment in progress",
        "Please wait for the current payment to complete",
        Icons.hourglass_empty,
      );
      return;
    }

    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    
    if (cartProvider.isEmpty) {
      _showErrorSnackBar(
        "Cart is empty",
        "Add items to your cart before proceeding to payment",
        Icons.shopping_cart_outlined,
      );
      return;
    }

    _isProcessing = true;

    try {
      // STEP 1: Check network connectivity
      if (!await _checkNetworkConnectivity()) {
        return;
      }

      // STEP 2: Show loading dialog with platform fee info
      _showNetworkAwareLoading();
      
      // STEP 3: Check for active orders
      print('🔍 Checking for active orders before payment...');
      final activeOrderResult = await ActiveOrderService.checkActiveOrder();
      
      if (activeOrderResult.hasActiveOrder) {
        print('❌ Active order found during payment: ${activeOrderResult.orderId}');
        Navigator.pop(context); // Close loading
        CartDialogs.showActiveOrderBlockDialog(context, activeOrderResult);
        return;
      }
      
      print('✅ No active orders found, proceeding with payment (total: ₹$total including platform fee)...');

      // STEP 4: Create Razorpay order with retries (total already includes platform fee)
      currentRazorpayOrderId = await _createRazorpayOrder(total);
      
      if (currentRazorpayOrderId == null) {
        Navigator.pop(context); // Close loading
        throw Exception('ORDER_CREATION_FAILED');
      }

      // STEP 5: Create reservation with total including platform fee
      print('🔄 Creating reservation for payment: $currentRazorpayOrderId');
      
      final reservationRequest = ReservationCreateRequest(
        paymentId: currentRazorpayOrderId!,
        cartItems: cartProvider.cart,
        menuMap: menuMap,
        totalAmount: total,  // ✅ This includes platform fee
      );

      currentReservation = await ReservationService.createReservation(reservationRequest);
      
      if (currentReservation == null) {
        Navigator.pop(context); // Close loading
        throw Exception('RESERVATION_FAILED');
      }

      print('✅ Reservation created: ${currentReservation!.id} with total ₹$total (including platform fee)');

      // STEP 6: Start payment
      Navigator.pop(context); // Close loading
      _startPaymentWithOrder();

    } catch (e) {
      _isProcessing = false;
      Navigator.pop(context); // Close loading if still open
      
      // Clean up if anything fails
      if (currentReservation != null && currentRazorpayOrderId != null) {
        await ReservationService.failReservation(currentRazorpayOrderId!);
      }
      
      _handlePaymentSetupError(e.toString());
    } finally {
      _isProcessing = false;
    }
  }

  /// Handle payment setup errors with user-friendly messages
  void _handlePaymentSetupError(String error) {
    String title = "Payment Setup Failed";
    String message = "Please try again";
    IconData icon = Icons.error_outline;
    SnackBarAction? action;

    if (error.contains('NETWORK_TIMEOUT')) {
      title = "Network Timeout";
      message = "Your connection is slow. Please check your internet and try again.";
      icon = Icons.wifi_off;
      action = SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: () => startPayment(),
      );
    } else if (error.contains('NETWORK_ERROR')) {
      title = "Connection Error";
      message = "Please check your internet connection and try again.";
      icon = Icons.signal_wifi_off;
      action = SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: () => startPayment(),
      );
    } else if (error.contains('AUTH_ERROR')) {
      title = "Authentication Error";
      message = "Please login again to continue.";
      icon = Icons.account_circle;
      action = SnackBarAction(
        label: 'Login',
        textColor: Colors.white,
        onPressed: () {
          Navigator.pushReplacementNamed(context, '/auth');
        },
      );
    } else if (error.contains('ORDER_CREATION_FAILED')) {
      title = "Order Creation Failed";
      message = "Unable to create payment order. Please try again.";
      icon = Icons.receipt_long;
      action = SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: () => startPayment(),
      );
    } else if (error.contains('RESERVATION_FAILED')) {
      title = "Items Unavailable";
      message = "Some items may no longer be available. Please refresh and try again.";
      icon = Icons.inventory_2;
      action = SnackBarAction(
        label: 'Refresh',
        textColor: Colors.white,
        onPressed: () {
          Navigator.pop(context); // Go back to menu
        },
      );
    } else if (error.contains('MAX_RETRIES_EXCEEDED')) {
      title = "Service Temporarily Unavailable";
      message = "Payment service is having issues. Please try again later.";
      icon = Icons.cloud_off;
    } else {
      title = "Payment Error";
      message = "Something went wrong. Please try again.";
      icon = Icons.error_outline;
      action = SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: () => startPayment(),
      );
    }

    _showErrorSnackBar(title, message, icon, action: action);
  }

  /// Show network-aware loading dialog with platform fee info
  void _showNetworkAwareLoading() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFFFFB703)),
            const SizedBox(height: 20),
            Text(
              "Setting up payment...",
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Amount: ₹${total.toStringAsFixed(2)} (incl. platform fee)",  // ✅ NEW: Show total with platform fee
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: const Color(0xFFFFB703),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "This may take a moment on slow connections",
              style: GoogleFonts.poppins(
                fontSize: 12,
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              backgroundColor: Colors.grey[200],
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFFB703)),
            ),
          ],
        ),
      ),
    );
  }

  /// Start payment with Razorpay order (total includes platform fee)
  void _startPaymentWithOrder() {
    if (currentRazorpayOrderId == null) {
      _showErrorSnackBar(
        "Payment setup failed",
        "Unable to initialize payment. Please try again.",
        Icons.error_outline,
      );
      return;
    }

    var options = {
      'key': 'rzp_live_RGMjFYcXzOvb2o',
      'amount': (total * 100).toInt(),  // ✅ Total includes platform fee
      'currency': 'INR',
      'name': 'Thintava',
      'description': 'Food Order Payment (incl. platform fee) - Items Reserved',  // ✅ Updated description
      'order_id': currentRazorpayOrderId,
      'prefill': {
        'contact': '',
        'email': FirebaseAuth.instance.currentUser?.email ?? '',
      },
      'theme': {
        'color': '#FFB703',
      },
      'notes': {
        'app': 'Thintava',
        'user_id': FirebaseAuth.instance.currentUser?.uid ?? '',
        'reservation_id': currentReservation?.id ?? '',
        'auto_capture': 'enabled',
        'includes_platform_fee': 'true',  // ✅ NEW: Mark payment as including platform fee
      }
    };

    try {
      print('🚀 Starting Razorpay payment with reservation: ${currentReservation?.id} for total ₹$total (including platform fee)');
      _razorpay.open(options);
    } catch (e) {
      debugPrint("Razorpay Error: $e");
      _showErrorSnackBar(
        "Payment gateway error",
        "Unable to open payment interface. Please try again.",
        Icons.payment,
        action: SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: () => _startPaymentWithOrder(),
        ),
      );
    }
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFFFFB703)),
            const SizedBox(height: 20),
            Text(
              "Processing payment...",
              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              "Please wait while we confirm your order",
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
    
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      print('✅ Payment successful: ${response.paymentId} for total ₹$total (including platform fee)');

      // Verify payment with retries
      final verificationResult = await _verifyPaymentWithRetry(response);

      if (verificationResult['success'] != true) {
        throw Exception('Payment verification failed');
      }

      print('✅ Payment verified and reservation completed');

      // Final check for active order
      final finalCheck = await ActiveOrderService.checkActiveOrder();
      if (finalCheck.hasActiveOrder) {
        Navigator.pop(context); // Close loading dialog
        
        _showErrorSnackBar(
          "Order conflict detected",
          "Payment completed but another order is active. Please contact support.",
          Icons.error_outline,
        );
        
        CartDialogs.showActiveOrderBlockDialog(context, finalCheck);
        return;
      }

      final cartProvider = Provider.of<CartProvider>(context, listen: false);
      
      // ✅ UPDATED: Create order document with platform fee breakdown
      final orderDocRef = await _createOrderDocument(user, cartProvider, response);

      print('✅ Order created successfully: ${orderDocRef.id} with total ₹$total (including platform fee)');
      
      // Clear cart and tracking
      cartProvider.clearCart();
      currentRazorpayOrderId = null;
      currentReservation = null;
      
      Navigator.pop(context);
      CartDialogs.showPaymentSuccessDialog(context, response, orderDocRef.id, total);

    } catch (e) {
      Navigator.pop(context);
      print('❌ Error processing successful payment: $e');
      
      _showErrorSnackBar(
        "Order processing failed",
        "Payment was successful but order creation failed. Please contact support with payment ID: ${response.paymentId}",
        Icons.error_outline,
      );
    }
  }

  /// Verify payment with retry mechanism
  Future<Map<String, dynamic>> _verifyPaymentWithRetry(PaymentSuccessResponse response) async {
    int retryCount = 0;
    const maxRetries = 3;
    
    while (retryCount < maxRetries) {
      try {
        final callable = FirebaseFunctions.instance.httpsCallable('verifyRazorpayPayment');
        
        final result = await callable.call({
          'razorpay_payment_id': response.paymentId,
          'razorpay_order_id': currentRazorpayOrderId,
          'razorpay_signature': response.signature,
        }).timeout(const Duration(seconds: 30));

        return result.data;
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          rethrow;
        }
        
        print('⏳ Payment verification retry ${retryCount}...');
        await Future.delayed(Duration(seconds: retryCount * 2));
      }
    }
    
    throw Exception('Payment verification failed after retries');
  }

  /// ✅ UPDATED: Create order document with platform fee breakdown
  Future<DocumentReference> _createOrderDocument(
    User user,
    CartProvider cartProvider,
    PaymentSuccessResponse response,
  ) async {
    final List<Map<String, dynamic>> orderItems = [];
    final cartProvider = Provider.of<CartProvider>(context, listen: false);
    
    // Calculate breakdown for order document
    Map<String, double> itemPrices = {};
    menuMap.forEach((id, data) {
      final price = data['price'];
      if (price != null) {
        itemPrices[id] = price is double ? price : double.parse(price.toString());
      }
    });
    
    final costBreakdown = cartProvider.getCostBreakdown(itemPrices);
    final subtotal = costBreakdown['subtotal']!;
    final platformFee = costBreakdown['platformFee']!;
    final totalWithFee = costBreakdown['total']!;
    
    cartProvider.cart.forEach((itemId, qty) {
      final itemData = menuMap[itemId];
      if (itemData != null) {
        orderItems.add({
          'id': itemId,
          'name': itemData['name'] ?? 'Unknown',
          'price': itemData['price'] ?? 0,
          'quantity': qty,
          'subtotal': (itemData['price'] ?? 0) * qty,
        });
      }
    });

    return await FirebaseFirestore.instance.collection('orders').add({
      'userId': user.uid,
      'userEmail': user.email,
      'items': orderItems,
      'status': 'Placed',
      'timestamp': Timestamp.now(),
      
      // ✅ NEW: Detailed cost breakdown including platform fee
      'subtotal': subtotal,
      'platformFee': platformFee,
      'total': totalWithFee,
      'totalAmount': totalWithFee,  // Keep this for backward compatibility
      
      // Payment info
      'paymentId': response.paymentId,
      'razorpayOrderId': currentRazorpayOrderId,
      'reservationId': currentReservation?.id,
      'paymentStatus': 'success',
      'autoCaptureEnabled': true,
      'reservationCompleted': true,
      
      // ✅ NEW: Platform fee metadata
      'hasPlatformFee': platformFee > 0,
      'platformFeeAmount': platformFee,
      'platformFeeCalculation': PlatformFeeCalculator.formatPlatformFee(subtotal),
    });
  }

  void _handlePaymentError(PaymentFailureResponse response) async {
    print('❌ Payment failed: ${response.code} - ${response.message}');
    
    // Release reservation
    if (currentReservation != null && currentRazorpayOrderId != null) {
      await ReservationService.failReservation(currentRazorpayOrderId!);
      print('✅ Reservation failed and items released');
    }

    // Clean up tracking
    currentRazorpayOrderId = null;
    currentReservation = null;

    // ✅ FIXED: Use correct Razorpay error handling
    String errorMessage = "Payment was cancelled or failed. Items have been released.";
    
    // Handle different error codes properly
    if (response.code != null) {
      switch (response.code) {
        case 0: // Network error
          errorMessage = "Network error during payment. Please check your connection and try again.";
          break;
        case 1: // Payment cancelled by user
          errorMessage = "Payment was cancelled. Items have been released from your cart.";
          break;
        case 2: // Invalid credentials or configuration error
          errorMessage = "Payment service configuration error. Please contact support.";
          break;
        default:
          errorMessage = "Payment failed: ${response.message ?? 'Unknown error'}. Items have been released.";
      }
    }

    _showErrorSnackBar(
      "Payment Failed",
      errorMessage,
      Icons.payment,
      action: SnackBarAction(
        label: 'Try Again',
        textColor: Colors.white,
        onPressed: () => startPayment(),
      ),
    );
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    _showInfoSnackBar(
      "External wallet selected",
      "Redirecting to ${response.walletName}",
      Icons.account_balance_wallet,
    );
  }

  /// Enhanced error snackbar
  void _showErrorSnackBar(String title, String message, IconData icon, {SnackBarAction? action}) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      message,
                      style: GoogleFonts.poppins(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: Colors.red[600],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 6),
          action: action,
        ),
      );
    }
  }

  /// Info snackbar
  void _showInfoSnackBar(String title, String message, IconData icon) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      message,
                      style: GoogleFonts.poppins(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          backgroundColor: Colors.orange[600],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}