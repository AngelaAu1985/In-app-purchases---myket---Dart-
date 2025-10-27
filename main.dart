// Copyright (c) 2023 Your Company. All rights reserved.
// Licensed under the MIT License.

library trivial_drive;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:lottie/lottie.dart';  // Add to pubspec.yaml: lottie: ^3.1.2

// Project Constants
const String _skuPremium = 'premium_upgrade';
const String _skuGas = 'gas_pack';
const String _skuInfiniteGas = 'infinite_gas_monthly';
const int _gasUnitsPerPack = 25;
const int _maxTankCapacity = 100;
const String _payloadPrefix = 'secure_payload_';
const String _premiumKey = 'is_premium';
const String _tankKey = 'gas_tank';
const String _milesKey = 'miles_driven';
const String _achievementsKey = 'achievements';
const String _highScoreKey = 'high_score';
const String _dailyRewardKey = 'last_daily_reward';
const int _milesPerDrive = 5;
const Duration _driveAnimationDuration = Duration(milliseconds: 800);
const int _dailyGasReward = 10;
const String _boostModeKey = 'boost_active_until';
const Duration _boostDuration = Duration(minutes: 5);

// Data Model
class GameState {
  final bool isPremium;
  final bool hasInfiniteGas;
  final int gasTank;
  final int milesDriven;
  final List<String> achievements;
  final int highScore;
  final bool isBoostActive;

  const GameState({
    required this.isPremium,
    required this.hasInfiniteGas,
    required this.gasTank,
    required this.milesDriven,
    required this.achievements,
    required this.highScore,
    this.isBoostActive = false,
  });

  GameState copyWith({
    bool? isPremium,
    bool? hasInfiniteGas,
    int? gasTank,
    int? milesDriven,
    List<String>? achievements,
    int? highScore,
    bool? isBoostActive,
  }) {
    return GameState(
      isPremium: isPremium ?? this.isPremium,
      hasInfiniteGas: hasInfiniteGas ?? this.hasInfiniteGas,
      gasTank: gasTank ?? this.gasTank,
      milesDriven: milesDriven ?? this.milesDriven,
      achievements: achievements ?? this.achievements,
      highScore: highScore ?? this.highScore,
      isBoostActive: isBoostActive ?? this.isBoostActive,
    );
  }
}

// Billing Service (Singleton-like with Base Methods)
abstract class BillingService {
  static final BillingService _instance = _InAppPurchaseBillingService._();
  factory BillingService() => _instance;

  Stream<GameState> get stateStream;
  Future<void> initialize();
  Future<bool> purchase(String sku, {bool isSubscription = false});
  Future<void> restorePurchases();
  Future<void> consume(String sku);
  Future<void> claimDailyReward();
  Future<void> activateBoostMode();
  Future<void> shareHighScore();
  bool checkHighScore(int newMiles);
  void dispose();

  // Base parent method for handling purchase verification
  static bool _verifyPayload(String payload, String expectedPrefix) {
    return payload.startsWith(expectedPrefix);
  }
}

// Implementation using in_app_purchase package
class _InAppPurchaseBillingService implements BillingService {
  final InAppPurchase _iap = InAppPurchase.instance;
  final StreamController<GameState> _stateController = StreamController<GameState>.broadcast();
  SharedPreferences? _prefs;
  GameState _currentState = const GameState(isPremium: false, hasInfiniteGas: false, gasTank: 50, milesDriven: 0, achievements: [], highScore: 0);

  _InAppPurchaseBillingService._();

  @override
  Stream<GameState> get stateStream => _stateController.stream;

  @override
  Future<void> initialize() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _loadSavedState();

      final bool available = await _iap.isAvailable();
      if (!available) {
        _updateState(_currentState.copyWith(gasTank: 0));  // Offline mode
        return;
      }

      final Stream<List<PurchaseDetails>> purchaseStream = _iap.purchaseStream;
      purchaseStream.listen(_handlePurchaseUpdate, onDone: () {}, onError: _handleError);

      await _restorePurchases();
      _updateState(_currentState);
    } catch (e) {
      debugPrint('Initialization error: $e');
    }
  }

  @override
  Future<bool> purchase(String sku, {bool isSubscription = false}) async {
    try {
      final String payload = _generateSecurePayload(sku);
      final ProductDetailsResponse response = await _iap.queryProductDetails({sku});
      if (response.notFoundIDs.isNotEmpty) {
        _handleError('Product $sku not found');
        return false;
      }

      final ProductDetails product = response.productDetails.first;
      final PurchaseParam param = PurchaseParam(productDetails: product, applicationUserData: payload);
      final bool success = isSubscription 
          ? await _iap.buyNonConsumable(purchaseParam: param)  // Subscriptions are non-consumable
          : (sku == _skuGas ? await _iap.buyConsumable(purchaseParam: param) : await _iap.buyNonConsumable(purchaseParam: param));
      return success;
    } catch (e) {
      _handleError('Purchase failed: $e');
      return false;
    }
  }

  @override
  Future<void> restorePurchases() async {
    try {
      await _iap.restorePurchases();
    } catch (e) {
      _handleError('Restore failed: $e');
    }
  }

  @override
  Future<void> consume(String sku) async {
    try {
      _saveState();
    } catch (e) {
      _handleError('Consume failed: $e');
    }
  }

  @override
  Future<void> claimDailyReward() async {
    try {
      final lastClaim = _prefs?.getInt(_dailyRewardKey) ?? 0;
      final today = DateTime.now().millisecondsSinceEpoch ~/ 86400000;  // Days since epoch
      if (lastClaim < today && _currentState.gasTank < _maxTankCapacity) {
        final newTank