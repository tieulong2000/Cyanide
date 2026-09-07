#import "LocationKeeper.h"

#import <CoreLocation/CoreLocation.h>

@interface CyanideLocationKeeper : NSObject <CLLocationManagerDelegate>

@property(nonatomic, strong) CLLocationManager *manager;

@end


@implementation CyanideLocationKeeper

- (instancetype)init
{
    self = [super init];

    if (self) {

        _manager =
            [[CLLocationManager alloc] init];

        _manager.delegate = self;

        /*
         * Standard location service.
         */
        _manager.desiredAccuracy =
            kCLLocationAccuracyBest;

        _manager.distanceFilter =
            kCLDistanceFilterNone;

        /*
         * Không để iOS tự pause vì nghĩ user đứng yên.
         */
        _manager.pausesLocationUpdatesAutomatically =
            NO;

        /*
         * Quan trọng nhất.
         */
        _manager.allowsBackgroundLocationUpdates =
            YES;

        /*
         * Có thể hiện blue indicator khi background.
         */
        if ([_manager respondsToSelector:
             @selector(setShowsBackgroundLocationIndicator:)]) {

            _manager.showsBackgroundLocationIndicator =
                YES;
        }

        /*
         * Nếu simulation mô phỏng đi bộ.
         */
        _manager.activityType =
            CLActivityTypeFitness;
    }

    return self;
}


- (void)locationManager:
    (CLLocationManager *)manager
    didUpdateLocations:
    (NSArray<CLLocation *> *)locations
{
    CLLocation *location =
        locations.lastObject;

    if (!location)
        return;

    NSLog(
        @"[LOCKEEPER] location %.8f %.8f speed=%.2f",
        location.coordinate.latitude,
        location.coordinate.longitude,
        location.speed
    );
}


- (void)locationManager:
    (CLLocationManager *)manager
    didFailWithError:
    (NSError *)error
{
    NSLog(
        @"[LOCKEEPER] error=%@",
        error
    );
}


- (void)locationManagerDidChangeAuthorization:
    (CLLocationManager *)manager
{
    NSLog(
        @"[LOCKEEPER] auth=%d",
        (int)manager.authorizationStatus
    );
}

@end


static CyanideLocationKeeper *g_locationKeeper = nil;


bool locationkeeper_start(void)
{
    if (g_locationKeeper) {
        NSLog(@"[LOCKEEPER] already active");
        return true;
    }

    if (![CLLocationManager locationServicesEnabled]) {

        NSLog(
            @"[LOCKEEPER] location services disabled"
        );

        return false;
    }

    g_locationKeeper =
        [[CyanideLocationKeeper alloc] init];

    CLAuthorizationStatus status;

    if (@available(iOS 14.0, *)) {

        status =
            g_locationKeeper.manager.authorizationStatus;

    } else {

        status =
            [CLLocationManager authorizationStatus];
    }

    NSLog(
        @"[LOCKEEPER] current auth=%d",
        (int)status
    );

    if (status ==
        kCLAuthorizationStatusNotDetermined) {

        /*
         * Bản test đầu dùng When In Use.
         *
         * Vì có background location mode +
         * allowsBackgroundLocationUpdates,
         * session đã start foreground có thể tiếp tục.
         */
        [
            g_locationKeeper.manager
            requestWhenInUseAuthorization
        ];
    }

    /*
     * PHẢI gọi khi Cyanide đang foreground.
     */
    [
        g_locationKeeper.manager
        startUpdatingLocation
    ];

    NSLog(
        @"[LOCKEEPER] startUpdatingLocation"
    );

    return true;
}


void locationkeeper_stop(void)
{
    if (!g_locationKeeper)
        return;

    [
        g_locationKeeper.manager
        stopUpdatingLocation
    ];

    g_locationKeeper.manager.delegate = nil;

    g_locationKeeper = nil;

    NSLog(
        @"[LOCKEEPER] stopped"
    );
}


bool locationkeeper_is_active(void)
{
    return g_locationKeeper != nil;
}