//
//  DMPasscode.m
//  DMPasscode
//
//  Created by Dylan Marriott on 20/09/14.
//  Copyright (c) 2014 Dylan Marriott. All rights reserved.
//

#import "DMPasscode.h"
#import "DMPasscodeInternalNavigationController.h"
#import "DMPasscodeInternalViewController.h"
#import "DMKeychain.h"
#import "AESCrypt.h"
#import "NSData+CommonCrypto.h"

#ifdef __IPHONE_8_0
#import <LocalAuthentication/LocalAuthentication.h>
#endif

#undef NSLocalizedString
#define NSLocalizedString(key, comment) \
[bundle localizedStringForKey:(key) value:@"" table:@"DMPasscodeLocalisation"]

static DMPasscode* instance;
static const NSString* KEYCHAIN_NAME = @"PSKey";
static NSBundle* bundle;
NSString * const DMUnlockErrorDomain = @"com.dmpasscode.error.unlock";

@interface DMPasscode () <DMPasscodeInternalViewControllerDelegate>
@end

@implementation DMPasscode {
    PasscodeCompletionBlock _completion;
    DMPasscodeInternalViewController* _passcodeViewController;
    int _mode; // 0 = setup, 1 = input
    int _count;
    NSString* _prevCode;
    DMPasscodeConfig* _config;
}

+ (void)initialize {
    [super initialize];
    instance = [[DMPasscode alloc] init];
    bundle = [DMPasscode bundleWithName:@"DMPasscode.bundle"];

}

- (instancetype)init {
    if (self = [super init]) {
        _config = [[DMPasscodeConfig alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deviceTokenSaved:)
                                                     name:@"DeviceTokenSaved"
                                                   object:nil];
    }
    return self;
}

- (void) deviceTokenSaved:(NSNotification *) notification {
    if (notification != nil && notification.userInfo != nil && [notification.userInfo objectForKey:@"device_token"] != nil) {
        _config.externalSecret = [notification.userInfo objectForKey:@"device_token"];
    }
}

+ (NSBundle*)bundleWithName:(NSString*)name {
    NSString* mainBundlePath = [[NSBundle mainBundle] resourcePath];
    NSString* frameworkBundlePath = [mainBundlePath stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:frameworkBundlePath]){
        return [NSBundle bundleWithPath:frameworkBundlePath];
    }
    return nil;
}

#pragma mark - Public
+ (void)setupPasscodeInViewController:(UIViewController *)viewController completion:(PasscodeCompletionBlock)completion {
    [instance setupPasscodeInViewController:viewController completion:completion];
}

+ (void)showPasscodeInViewController:(UIViewController *)viewController completion:(PasscodeCompletionBlock)completion {
    [instance showPasscodeInViewController:viewController forcePinEntry:NO reason:NSLocalizedString(@"dmpasscode_touchid_reason", nil) completion:completion];
}

+ (void)showPasscodeInViewController:(UIViewController *)viewController forcePinEntry:(BOOL)force completion:(PasscodeCompletionBlock)completion {
    [instance showPasscodeInViewController:viewController forcePinEntry:force reason:NSLocalizedString(@"dmpasscode_touchid_reason", nil) completion:completion];
}

+ (void)showPasscodeInViewController:(UIViewController *)viewController forcePinEntry:(BOOL)force reason:(NSString*)reason completion:(PasscodeCompletionBlock)completion {
  [instance showPasscodeInViewController:viewController forcePinEntry:force reason:reason completion:completion];
}

+ (void)removePasscode {
    [instance removePasscode];
}

+ (BOOL)isPasscodeSet {
    return [instance isPasscodeSet];
}

+ (void)setConfig:(DMPasscodeConfig *)config {
    [instance setConfig:config];
}

#pragma mark - Instance methods
- (void)setupPasscodeInViewController:(UIViewController *)viewController completion:(PasscodeCompletionBlock)completion {
    _completion = completion;
    [self openPasscodeWithMode:0 viewController:viewController];
}

-(void) handleEnteredBackground {
  [self closeAndNotify:NO withError:nil];
}

- (void)showPasscodeInViewController:(UIViewController *)viewController forcePinEntry:(BOOL)force reason:(NSString*)reason completion:(PasscodeCompletionBlock)completion {
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleEnteredBackground)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];

    NSAssert([self isPasscodeSet], @"No passcode set");
    _completion = completion;
    if (force) {
      NSLog(@"Forcing pin entry!");
      [self openPasscodeWithMode:1 viewController:viewController];
    } else {
      LAContext* context = [[LAContext alloc] init];
      if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:nil]) {
          [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics localizedReason:reason reply:^(BOOL success, NSError* error) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  if (error) {
                      switch (error.code) {
                          case LAErrorUserCancel:
                              NSLog(@"LAErrorUserCancel");
                              // _completion(NO, nil);
                              [self openPasscodeWithMode:1 viewController:viewController];
                              break;
                          case LAErrorSystemCancel:
                              NSLog(@"LAErrorSystemCancel");
                              // _completion(NO, nil);
                              // [self openPasscodeWithMode:1 viewController:viewController];
                              [[NSNotificationCenter defaultCenter] postNotificationName:@"TouchIdCancel" object:self userInfo:nil];
                              break;
                          case LAErrorAuthenticationFailed:
                              NSLog(@"LAErrorAuthenticationFailed");
                              // _completion(NO, error);
                              [self openPasscodeWithMode:1 viewController:viewController];
                              break;
                          case LAErrorPasscodeNotSet:
                          case LAErrorTouchIDNotEnrolled:
                          case LAErrorTouchIDNotAvailable:
                          case LAErrorUserFallback:
                              NSLog(@"LAErrorUserFallback");
                              [self openPasscodeWithMode:1 viewController:viewController];
                              break;
                      }
                  } else {
                      if (_config.persistPin) {
                          NSString *uuidStr = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
                          NSData *data = [uuidStr dataUsingEncoding:NSUTF8StringEncoding];
                          NSData *dataSha256 = [data SHA256Hash];
                          NSString* uuidSha256Str = [dataSha256 description];
                          NSString *appInstallationId = [[NSUserDefaults standardUserDefaults] stringForKey:@"appInstallationId"];
                          if (![appInstallationId isEqualToString:uuidSha256Str]) {
                              [[NSNotificationCenter defaultCenter] postNotificationName:@"appInstallationIdChanged" object:nil];
                          }
                          NSString *secretPassword = [NSString stringWithFormat:@"%@%@", uuidStr, _config.externalSecret];
                          NSString *encSecret = [[DMKeychain defaultKeychain] objectForKey:KEYCHAIN_NAME];
                          NSString *mySecret = [AESCrypt decrypt:encSecret password:secretPassword];
                          if (mySecret != nil) {
                              [[NSNotificationCenter defaultCenter] postNotificationName:@"PinCode" object:self userInfo:@{ @"code": mySecret }];
                              _completion(success, nil);
                          } else {
                              if (_config.externalSecret == nil) {
                                  NSLog(@"No external secret set! Using fallback!");
                              }
                              [self openPasscodeWithMode:1 viewController:viewController];
                          }
                      } else {
                          _completion(success, nil);
                      }
                  }
              });
          }];
      } else {
          NSLog(@"No TouchId!");
          // no touch id available
          [self openPasscodeWithMode:1 viewController:viewController];
      }
    }
}

- (void)removePasscode {
    [[DMKeychain defaultKeychain] removeObjectForKey:KEYCHAIN_NAME];
}

- (BOOL)isPasscodeSet {
    BOOL ret = [[DMKeychain defaultKeychain] objectForKey:KEYCHAIN_NAME] != nil;
    return ret;
}

- (void)setConfig:(DMPasscodeConfig *)config {
    _config = config;
}

#pragma mark - Private
- (void)openPasscodeWithMode:(int)mode viewController:(UIViewController *)viewController {
    _mode = mode;
    _count = 0;
    _passcodeViewController = [[DMPasscodeInternalViewController alloc] initWithDelegate:self config:_config];
    DMPasscodeInternalNavigationController* nc = [[DMPasscodeInternalNavigationController alloc] initWithRootViewController:_passcodeViewController];
    [nc setModalPresentationStyle:UIModalPresentationFormSheet];
    [viewController presentViewController:nc animated:YES completion:nil];
    if (_mode == 0) {
        [_passcodeViewController setInstructions:NSLocalizedString(@"dmpasscode_enter_new_code", nil)];
    } else if (_mode == 1) {
        [_passcodeViewController setInstructions:NSLocalizedString(@"dmpasscode_enter_to_unlock", nil)];
    }
}

- (void)closeAndNotify:(BOOL)success withError:(NSError *)error {
    [_passcodeViewController dismissViewControllerAnimated:YES completion:^() {
        _completion(success, error);
    }];
}

#pragma mark - DMPasscodeInternalViewControllerDelegate
- (void)enteredCode:(NSString *)code {
    if (_mode == 0) {
        if (_count == 0) {
            _prevCode = code;
            [_passcodeViewController setInstructions:NSLocalizedString(@"dmpasscode_repeat", nil)];
            [_passcodeViewController setErrorMessage:@""];
            [_passcodeViewController reset];
        } else if (_count == 1) {
            if ([code isEqualToString:_prevCode]) {
              NSString *matchphrase1 = @"^([0-9]+[a-zA-Z]+|[a-zA-Z]+[0-9]+)[0-9a-zA-Z]*$";
              NSPredicate *matchPred1 = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", matchphrase1];
              if ([matchPred1 evaluateWithObject:code]) {
                NSString *uuidStr = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
                NSData *data = [uuidStr dataUsingEncoding:NSUTF8StringEncoding];
                NSData *dataSha256 = [data SHA256Hash];
                NSString* uuidSha256Str = [dataSha256 description];
                [[NSUserDefaults standardUserDefaults] setObject:uuidSha256Str forKey:@"appInstallationId"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                if (_config.persistPin) {
                    NSString *secretPassword = [NSString stringWithFormat:@"%@%@", uuidStr, _config.externalSecret];
                    NSString *mySecret = [AESCrypt encrypt:code password:secretPassword];
                    [[DMKeychain defaultKeychain] setObject:mySecret forKey:KEYCHAIN_NAME];
                } else {
                    NSString *mySecret = [AESCrypt encrypt:uuidStr password:code];
                    [[DMKeychain defaultKeychain] setObject:mySecret forKey:KEYCHAIN_NAME];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:@"PinCode" object:self userInfo:@{ @"code": code }];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"TouchIdAlert" object:self userInfo:nil];
                [self closeAndNotify:YES withError:nil];
              } else {
                [_passcodeViewController setInstructions:NSLocalizedString(@"dmpasscode_enter_new_code", nil)];
                [_passcodeViewController setErrorMessage:NSLocalizedString(@"dmpasscode_not_valid", nil)];
                [_passcodeViewController reset];
                _count = 0;
                return;
              }
            } else {
                [_passcodeViewController setInstructions:NSLocalizedString(@"dmpasscode_enter_new_code", nil)];
                [_passcodeViewController setErrorMessage:NSLocalizedString(@"dmpasscode_not_match", nil)];
                [_passcodeViewController reset];
                _count = 0;
                return;
            }
        }
    } else if (_mode == 1) {
        NSString *uuidStr = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        NSData *data = [uuidStr dataUsingEncoding:NSUTF8StringEncoding];
        NSData *dataSha256 = [data SHA256Hash];
        NSString* uuidSha256Str = [dataSha256 description];
        NSString *appInstallationId = [[NSUserDefaults standardUserDefaults] stringForKey:@"appInstallationId"];
        if (![appInstallationId isEqualToString:uuidSha256Str]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"appInstallationIdChanged" object:nil];
        }
        bool valid = NO;
        
        if (_config.persistPin) {
            NSString *secretPassword = [NSString stringWithFormat:@"%@%@", uuidStr, _config.externalSecret];
            NSString *encSecret = [[DMKeychain defaultKeychain] objectForKey:KEYCHAIN_NAME];
            NSString *mySecret = [AESCrypt decrypt:encSecret password:secretPassword];
            if (mySecret == code) {
                valid = YES;
                code = mySecret;
            }
        } else {
            NSString *theSecret = [AESCrypt encrypt:uuidStr password:code];
            valid = [theSecret isEqualToString:[[DMKeychain defaultKeychain] objectForKey:KEYCHAIN_NAME]];
        }
        
        if (valid) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PinCode" object:self userInfo:@{ @"code": code }];
            [self closeAndNotify:YES withError:nil];
        } else {
            /*if (_count == 1) {
                [_passcodeViewController setErrorMessage:NSLocalizedString(@"dmpasscode_1_left", nil)];
            } else {
                [_passcodeViewController setErrorMessage:[NSString stringWithFormat:NSLocalizedString(@"dmpasscode_n_left", nil), 2 - _count]];
            }*/
            [_passcodeViewController setErrorMessage:NSLocalizedString(@"dmpasscode_0_left", nil)];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PinEnterFailure" object:self userInfo:nil];
            [_passcodeViewController reset];
            /*if (_count >= 2) { // max 3 attempts
                NSError *errorMatchingPins = [NSError errorWithDomain:DMUnlockErrorDomain code:DMErrorUnlocking userInfo:nil];
                [self closeAndNotify:NO withError:errorMatchingPins];
            }*/
        }
    }
    _count++;
}

- (void)canceled {
    _completion(NO, nil);
}

@end
