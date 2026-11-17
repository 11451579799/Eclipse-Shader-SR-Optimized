#if WATER_SIM_SCALE == 0
    #if WATER_SIM_DISTANCE == 1
        #define WATER_SIM_WORK_GROUPS ivec3(16, 16, 1)
    #elif WATER_SIM_DISTANCE == 2
        #define WATER_SIM_WORK_GROUPS ivec3(32, 32, 1)
    #elif WATER_SIM_DISTANCE == 3
        #define WATER_SIM_WORK_GROUPS ivec3(48, 48, 1)
    #else
        #define WATER_SIM_WORK_GROUPS ivec3(64, 64, 1)
    #endif
#elif WATER_SIM_SCALE == 1
    #if WATER_SIM_DISTANCE == 1
        #define WATER_SIM_WORK_GROUPS ivec3(32, 32, 1)
    #elif WATER_SIM_DISTANCE == 2
        #define WATER_SIM_WORK_GROUPS ivec3(64, 64, 1)
    #elif WATER_SIM_DISTANCE == 3
        #define WATER_SIM_WORK_GROUPS ivec3(96, 96, 1)
    #else
        #define WATER_SIM_WORK_GROUPS ivec3(128, 128, 1)
    #endif
#else
    #if WATER_SIM_DISTANCE == 1
        #define WATER_SIM_WORK_GROUPS ivec3(64, 64, 1)
    #elif WATER_SIM_DISTANCE == 2
        #define WATER_SIM_WORK_GROUPS ivec3(128, 128, 1)
    #elif WATER_SIM_DISTANCE == 3
        #define WATER_SIM_WORK_GROUPS ivec3(192, 192, 1)
    #else
        #define WATER_SIM_WORK_GROUPS ivec3(256, 256, 1)
    #endif
#endif

#define WATER_SIM_SHOULD_UPDATE (abs(frameTimeCounter - lastFrameTimeCount) > WATER_SIM_FRAMETIME && (!noSimOngoing || onWaterSurface))
