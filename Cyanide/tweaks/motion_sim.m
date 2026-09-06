#import "motion_sim.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <pthread.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import "../LogTextView.h"

@interface MotionSimAccelerometerData : CMAccelerometerData

@property (nonatomic, assign) CMAcceleration simAcceleration;
@property (nonatomic, assign) NSTimeInterval simTimestamp;

@end


@implementation MotionSimAccelerometerData

- (CMAcceleration)acceleration
{
    return self.simAcceleration;
}

- (NSTimeInterval)timestamp
{
    return self.simTimestamp;
}

@end

@interface MotionSimGyroData : CMGyroData

@property (nonatomic, assign) CMRotationRate simRotationRate;
@property (nonatomic, assign) NSTimeInterval simTimestamp;

@end


@implementation MotionSimGyroData

- (CMRotationRate)rotationRate
{
    return self.simRotationRate;
}

- (NSTimeInterval)timestamp
{
    return self.simTimestamp;
}

@end


static pthread_mutex_t g_motion_lock = PTHREAD_MUTEX_INITIALIZER;

static bool g_motion_active = false;
static double g_motion_start_time = 0.0;

static double g_motion_speed_kmh = 5.0;
static double g_motion_intensity = 1.0;

static int accLogCount = 0;
static int gyroLogCount = 0;

// static CMAccelerometerData *(*orig_accelerometerData)(
//     id self,
//     SEL _cmd
// );

// static CMGyroData *(*orig_gyroData)(
//     id self,
//     SEL _cmd
// );

static void (*orig_startAccelerometerUpdatesToQueue)(
    id self,
    SEL _cmd,
    NSOperationQueue *queue,
    CMAccelerometerHandler handler
);

static void motionsim_startAccelerometerUpdatesToQueue(
    id self,
    SEL _cmd,
    NSOperationQueue *queue,
    CMAccelerometerHandler handler)
{
    if (!handler) {
        orig_startAccelerometerUpdatesToQueue(
            self,
            _cmd,
            queue,
            handler
        );
        return;
    }

    CMAccelerometerHandler wrapped =
    ^(CMAccelerometerData *data, NSError *error) {

        if (!motionsim_is_active()) {
            handler(data, error);
            return;
        }

        MotionSimSample sample =
            motionsim_current_sample();

        MotionSimAccelerometerData *fake =
            [[MotionSimAccelerometerData alloc] init];

        CMAcceleration acceleration;

        acceleration.x = sample.accelX;
        acceleration.y = sample.accelY;
        acceleration.z = sample.accelZ;

        fake.simAcceleration = acceleration;

        /*
        * CoreMotion timestamp là thời gian tính từ lúc boot.
        */
        fake.simTimestamp =
            NSProcessInfo.processInfo.systemUptime;

        log_user(
            "[MOTIONSIM][ACC] generated %.3f %.3f %.3f\n",
            acceleration.x,
            acceleration.y,
            acceleration.z
        );

        handler(fake, nil);
    };

    orig_startAccelerometerUpdatesToQueue(
        self,
        _cmd,
        queue,
        wrapped
    );
}


static void (*orig_startGyroUpdatesToQueue)(
    id self,
    SEL _cmd,
    NSOperationQueue *queue,
    CMGyroHandler handler
);

static void motionsim_startGyroUpdatesToQueue(
    id self,
    SEL _cmd,
    NSOperationQueue *queue,
    CMGyroHandler handler)
{
    if (!handler) {
        orig_startGyroUpdatesToQueue(
            self,
            _cmd,
            queue,
            handler
        );
        return;
    }

    CMGyroHandler wrapped =
    ^(CMGyroData *data, NSError *error) {

        if (!motionsim_is_active()) {
            handler(data, error);
            return;
        }

        MotionSimSample sample =
            motionsim_current_sample();

        MotionSimGyroData *fake =
            [[MotionSimGyroData alloc] init];

        CMRotationRate rotation;

        rotation.x = sample.gyroX;
        rotation.y = sample.gyroY;
        rotation.z = sample.gyroZ;

        fake.simRotationRate = rotation;

        fake.simTimestamp =
            NSProcessInfo.processInfo.systemUptime;

        log_user(
            "[MOTIONSIM][GYRO] generated %.3f %.3f %.3f\n",
            rotation.x,
            rotation.y,
            rotation.z
        );

        handler(fake, nil);
    };

    orig_startGyroUpdatesToQueue(
        self,
        _cmd,
        queue,
        wrapped
    );
}

static bool g_motion_hooks_installed = false;

static void motionsim_install_hooks(void)
{
    if (g_motion_hooks_installed)
        return;

    Class cls =
        NSClassFromString(@"CMMotionManager");

    if (!cls) {
        NSLog(@"[MOTIONSIM] CMMotionManager not found");
        return;
    }

    Method accelMethod =
        class_getInstanceMethod(
            cls,
            @selector(
                startAccelerometerUpdatesToQueue:
                withHandler:
            )
        );

    if (accelMethod) {

        orig_startAccelerometerUpdatesToQueue =
            (void *)method_getImplementation(
                accelMethod
            );

        method_setImplementation(
            accelMethod,
            (IMP)motionsim_startAccelerometerUpdatesToQueue
        );
        log_user("[MOTIONSIM] accelerometer hook installed\n");
    }

    Method gyroMethod =
        class_getInstanceMethod(
            cls,
            @selector(
                startGyroUpdatesToQueue:
                withHandler:
            )
        );

    if (gyroMethod) {

        orig_startGyroUpdatesToQueue =
            (void *)method_getImplementation(
                gyroMethod
            );

        method_setImplementation(
            gyroMethod,
            (IMP)motionsim_startGyroUpdatesToQueue
        );

        log_user("[MOTIONSIM] gyro hook installed\n");
    }

    g_motion_hooks_installed = true;
}

static double motion_clamp(double value,
                           double minValue,
                           double maxValue)
{
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}

bool motionsim_start(const MotionSimConfig *config)
{
    if (!config)
        return false;

    motionsim_install_hooks();
    double speed = config->speedKmh;
    double intensity = config->intensity;

    if (!isfinite(speed) || speed <= 0.0)
        speed = 5.0;

    if (!isfinite(intensity) || intensity <= 0.0)
        intensity = 1.0;

    speed = motion_clamp(speed, 0.5, 50.0);
    intensity = motion_clamp(intensity, 0.1, 5.0);

    pthread_mutex_lock(&g_motion_lock);

    g_motion_speed_kmh = speed;
    g_motion_intensity = intensity;
    g_motion_start_time = CACurrentMediaTime();
    g_motion_active = true;

    pthread_mutex_unlock(&g_motion_lock);

    log_user(
    "[MOTIONSIM] started speed=%.2f km/h intensity=%.2f\n",
        speed,
        intensity
    );

    return true;
}

bool motionsim_stop(void)
{
    pthread_mutex_lock(&g_motion_lock);

    g_motion_active = false;

    pthread_mutex_unlock(&g_motion_lock);

    NSLog(@"[MOTIONSIM] stopped");

    return true;
}

bool motionsim_is_active(void)
{
    pthread_mutex_lock(&g_motion_lock);

    bool active = g_motion_active;

    pthread_mutex_unlock(&g_motion_lock);

    return active;
}

MotionSimSample motionsim_current_sample(void)
{
    MotionSimSample sample = {0};

    pthread_mutex_lock(&g_motion_lock);

    bool active = g_motion_active;
    double startTime = g_motion_start_time;
    double speedKmh = g_motion_speed_kmh;
    double intensity = g_motion_intensity;

    pthread_mutex_unlock(&g_motion_lock);

    if (!active)
        return sample;

    double t = CACurrentMediaTime() - startTime;

    /*
     * Walking cadence.
     *
     * ~5 km/h -> khoảng 1.8 Hz
     */
    double frequency =
        1.2 + speedKmh * 0.12;

    frequency =
        motion_clamp(frequency, 1.0, 3.0);

    double phase =
        t * 2.0 * M_PI * frequency;

    /*
     * Accelerometer values tính theo g.
     *
     * Đây là dao động tương đối, chưa phải dữ liệu
     * CoreMotion được inject vào app khác.
     */
    sample.accelX =
        0.035 *
        intensity *
        sin(phase);

    sample.accelY =
        0.055 *
        intensity *
        sin(phase + 0.8);

    sample.accelZ =
        1.0 +
        0.12 *
        intensity *
        sin(phase);

    /*
     * Gyroscope: rad/s
     */
    sample.gyroX =
        0.07 *
        intensity *
        sin(phase + 0.4);

    sample.gyroY =
        0.05 *
        intensity *
        sin(phase + 1.1);

    sample.gyroZ =
        0.10 *
        intensity *
        sin(phase);

    return sample;
}



