// lib/services/stock_management_service.dart
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';

class StockManagementService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Check if items are available in required quantities
  static Future<StockCheckResult> checkStockAvailability(Map<String, int> cartItems) async {
    List<String> outOfStockItems = [];
    List<String> insufficientStockItems = [];
    Map<String, int> availableStock = {};
    bool isValid = true;

    try {
      for (String itemId in cartItems.keys) {
        final requestedQuantity = cartItems[itemId] ?? 0;
        
        final doc = await _firestore.collection('menuItems').doc(itemId).get();
        
        if (doc.exists) {
          final data = doc.data()!;
          final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
          final currentStock = data['quantity'] ?? 0;
          final itemName = data['name'] ?? 'Unknown Item';
          
          availableStock[itemId] = currentStock;
          
          if (!hasUnlimitedStock) {
            if (currentStock <= 0) {
              outOfStockItems.add(itemName);
              isValid = false;
            } else if (currentStock < requestedQuantity) {
              insufficientStockItems.add(
                '$itemName (Available: $currentStock, Requested: $requestedQuantity)'
              );
              isValid = false;
            }
          }
        } else {
          outOfStockItems.add('Item not found');
          isValid = false;
        }
      }
    } catch (e) {
      print('Error checking stock availability: $e');
      isValid = false;
    }

    return StockCheckResult(
      isValid: isValid,
      outOfStockItems: outOfStockItems,
      insufficientStockItems: insufficientStockItems,
      availableStock: availableStock,
    );
  }

  /// Update stock quantities after order placement
  static Future<bool> updateStockAfterOrder(Map<String, int> orderItems) async {
    try {
      WriteBatch batch = _firestore.batch();
      
      for (String itemId in orderItems.keys) {
        final orderedQuantity = orderItems[itemId] ?? 0;
        final docRef = _firestore.collection('menuItems').doc(itemId);
        
        // Get current data
        final doc = await docRef.get();
        if (doc.exists) {
          final data = doc.data()!;
          final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
          
          if (!hasUnlimitedStock) {
            final currentStock = data['quantity'] ?? 0;
            final newStock = currentStock - orderedQuantity;
            
            // Update the stock quantity
            batch.update(docRef, {
              'quantity': newStock >= 0 ? newStock : 0,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            
            print('📦 Stock update: $itemId: $currentStock -> ${newStock >= 0 ? newStock : 0}');
          }
        }
      }
      
      // Commit all updates atomically
      await batch.commit();
      print('✅ All stock quantities updated successfully');
      return true;
    } catch (e) {
      print('❌ Error updating stock quantities: $e');
      return false;
    }
  }

  /// Restore stock quantities (useful for order cancellations)
  static Future<bool> restoreStock(Map<String, int> orderItems) async {
    try {
      WriteBatch batch = _firestore.batch();
      
      for (String itemId in orderItems.keys) {
        final restoredQuantity = orderItems[itemId] ?? 0;
        final docRef = _firestore.collection('menuItems').doc(itemId);
        
        // Get current data
        final doc = await docRef.get();
        if (doc.exists) {
          final data = doc.data()!;
          final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
          
          if (!hasUnlimitedStock) {
            final currentStock = data['quantity'] ?? 0;
            final newStock = currentStock + restoredQuantity;
            
            // Update the stock quantity
            batch.update(docRef, {
              'quantity': newStock,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            
            print('📦 Stock restore: $itemId: $currentStock -> $newStock');
          }
        }
      }
      
      // Commit all updates atomically
      await batch.commit();
      print('✅ All stock quantities restored successfully');
      return true;
    } catch (e) {
      print('❌ Error restoring stock quantities: $e');
      return false;
    }
  }

  /// Get current stock status for a single item
  static Future<ItemStockStatus> getItemStockStatus(String itemId) async {
    try {
      final doc = await _firestore.collection('menuItems').doc(itemId).get();
      
      if (doc.exists) {
        final data = doc.data()!;
        final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
        final quantity = data['quantity'] ?? 0;
        final available = data['available'] ?? false;
        
        if (!available) {
          return ItemStockStatus.unavailable;
        } else if (hasUnlimitedStock) {
          return ItemStockStatus.unlimited;
        } else if (quantity <= 0) {
          return ItemStockStatus.outOfStock;
        } else if (quantity <= 5) {
          return ItemStockStatus.lowStock;
        } else {
          return ItemStockStatus.inStock;
        }
      } else {
        return ItemStockStatus.notFound;
      }
    } catch (e) {
      print('Error getting item stock status: $e');
      return ItemStockStatus.error;
    }
  }

  /// Get low stock items (for admin notifications)
  static Future<List<Map<String, dynamic>>> getLowStockItems({int threshold = 5}) async {
    try {
      final snapshot = await _firestore
          .collection('menuItems')
          .where('hasUnlimitedStock', isEqualTo: false)
          .where('quantity', isLessThanOrEqualTo: threshold)
          .where('available', isEqualTo: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['name'] ?? 'Unknown Item',
          'quantity': data['quantity'] ?? 0,
          'price': data['price'] ?? 0.0,
        };
      }).toList();
    } catch (e) {
      print('Error getting low stock items: $e');
      return [];
    }
  }

  /// Get out of stock items
  static Future<List<Map<String, dynamic>>> getOutOfStockItems() async {
    try {
      final snapshot = await _firestore
          .collection('menuItems')
          .where('hasUnlimitedStock', isEqualTo: false)
          .where('quantity', isEqualTo: 0)
          .where('available', isEqualTo: true)
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['name'] ?? 'Unknown Item',
          'price': data['price'] ?? 0.0,
        };
      }).toList();
    } catch (e) {
      print('Error getting out of stock items: $e');
      return [];
    }
  }

  /// Validate cart against current stock (real-time check)
  static Future<CartValidationResult> validateCart(Map<String, int> cartItems) async {
    List<String> itemsToRemove = [];
    Map<String, int> itemsToUpdate = {};
    
    try {
      for (String itemId in cartItems.keys) {
        final cartQuantity = cartItems[itemId] ?? 0;
        
        final doc = await _firestore.collection('menuItems').doc(itemId).get();
        
        if (doc.exists) {
          final data = doc.data()!;
          final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
          final currentStock = data['quantity'] ?? 0;
          final available = data['available'] ?? false;
          
          if (!available) {
            itemsToRemove.add(itemId);
          } else if (!hasUnlimitedStock) {
            if (currentStock <= 0) {
              itemsToRemove.add(itemId);
            } else if (currentStock < cartQuantity) {
              itemsToUpdate[itemId] = currentStock;
            }
          }
        } else {
          itemsToRemove.add(itemId);
        }
      }
    } catch (e) {
      print('Error validating cart: $e');
    }
    
    return CartValidationResult(
      isValid: itemsToRemove.isEmpty && itemsToUpdate.isEmpty,
      itemsToRemove: itemsToRemove,
      itemsToUpdate: itemsToUpdate,
    );
  }

  /// Check if specific quantity can be added to cart
  static Future<bool> canAddToCart(String itemId, int currentCartQuantity, int additionalQuantity) async {
    try {
      final doc = await _firestore.collection('menuItems').doc(itemId).get();
      
      if (doc.exists) {
        final data = doc.data()!;
        final hasUnlimitedStock = data['hasUnlimitedStock'] ?? false;
        final availableStock = data['quantity'] ?? 0;
        final available = data['available'] ?? false;
        
        if (!available) return false;
        if (hasUnlimitedStock) return true;
        
        final totalRequested = currentCartQuantity + additionalQuantity;
        return totalRequested <= availableStock;
      }
      return false;
    } catch (e) {
      print('Error checking if can add to cart: $e');
      return false;
    }
  }
}

/// Result class for stock check operations
class StockCheckResult {
  final bool isValid;
  final List<String> outOfStockItems;
  final List<String> insufficientStockItems;
  final Map<String, int> availableStock;

  StockCheckResult({
    required this.isValid,
    required this.outOfStockItems,
    required this.insufficientStockItems,
    required this.availableStock,
  });
}

/// Result class for cart validation
class CartValidationResult {
  final bool isValid;
  final List<String> itemsToRemove;
  final Map<String, int> itemsToUpdate;

  CartValidationResult({
    required this.isValid,
    required this.itemsToRemove,
    required this.itemsToUpdate,
  });
}

/// Enum for item stock status
enum ItemStockStatus {
  unlimited,
  inStock,
  lowStock,
  outOfStock,
  unavailable,
  notFound,
  error,
}

/// Extension for ItemStockStatus to get display properties
extension ItemStockStatusExtension on ItemStockStatus {
  String get displayText {
    switch (this) {
      case ItemStockStatus.unlimited:
        return 'Unlimited';
      case ItemStockStatus.inStock:
        return 'In Stock';
      case ItemStockStatus.lowStock:
        return 'Low Stock';
      case ItemStockStatus.outOfStock:
        return 'Out of Stock';
      case ItemStockStatus.unavailable:
        return 'Unavailable';
      case ItemStockStatus.notFound:
        return 'Not Found';
      case ItemStockStatus.error:
        return 'Error';
    }
  }

    Color get color {
      switch (this) {
        case ItemStockStatus.unlimited:
          return Color(0xFF2196F3); // Blue
        case ItemStockStatus.inStock:
          return Color(0xFF4CAF50); // Green
        case ItemStockStatus.lowStock:
          return Color(0xFFFF9800); // Orange
        case ItemStockStatus.outOfStock:
          return Color(0xFFF44336); // Red
        case ItemStockStatus.unavailable:
          return Color(0xFF9E9E9E); // Grey
        case ItemStockStatus.notFound:
          return Color(0xFF9E9E9E); // Grey
        case ItemStockStatus.error:
          return Color(0xFFF44336); // Red
      }
    }

  bool get canAddToCart {
    switch (this) {
      case ItemStockStatus.unlimited:
      case ItemStockStatus.inStock:
      case ItemStockStatus.lowStock:
        return true;
      case ItemStockStatus.outOfStock:
      case ItemStockStatus.unavailable:
      case ItemStockStatus.notFound:
      case ItemStockStatus.error:
        return false;
    }
  }
}