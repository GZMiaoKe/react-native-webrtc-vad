#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(RNWebrtcVad, RCTEventEmitter)

RCT_EXTERN_METHOD(start:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stop:(BOOL)discard resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(audioDeviceSettings:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)

@end
