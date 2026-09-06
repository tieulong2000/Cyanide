#ifndef motion_sim_h
#define motion_sim_h

#include <stdbool.h>

typedef struct {
    double speedKmh;
    double intensity;
} MotionSimConfig;

typedef struct {
    double accelX;
    double accelY;
    double accelZ;

    double gyroX;
    double gyroY;
    double gyroZ;
} MotionSimSample;

bool motionsim_start(const MotionSimConfig *config);
bool motionsim_stop(void);
bool motionsim_is_active(void);

MotionSimSample motionsim_current_sample(void);

#endif