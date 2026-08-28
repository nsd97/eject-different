# Eject Different Autonomous Agents

## System Overview

Eject Different operates as an autonomous agent system that continuously monitors your Apple Silicon MacBook's motion sensors and automatically handles external disk ejection with minimal user intervention. The system functions as an always-on daemon with intelligent knock detection, Time Machine awareness, and safe disk management.

## Core Agents

### 1. SPUAccelerometerService Agent
**Role**: Hardware interface and sensor data collection
**Responsibilities**:
- Manages Apple SPU HID device connections (accelerometer usage 3, gyroscope usage 9)
- Establishes IOKit HID connections for real-time sensor data streaming
- Handles device lifecycle: startup, data processing, shutdown
- Provides thread-safe data access through `onSample` and `onGyroSample` callbacks
- Implements driver wake procedures to ensure sensor responsiveness

**Key Behaviors**:
- Automatic sensor reconnection on failures
- Maintains continuous data flow without user interaction
- Supports both accelerometer and gyroscope event streams
- Uses NSLock for thread-safe operations with `LockedBox`

### 2. TripleKnockDetector Agent  
**Role**: Pattern recognition and knock analysis
**Responsibilities**:
- Processes acceleration and rotational data from SPU sensors
- Implements intelligent knock detection algorithms:
  - Low-pass filtering for signal smoothing
  - High-pass filtering for edge detection  
  - Jerk analysis for impulse detection
  - Adaptive thresholding based on signal characteristics
- Maintains knock sequence state (single, double, triple patterns)
- Provides cooldown management to prevent false positives
- Emits knock events for orchestration

**Key Behaviors**:
- Distinguishes true triple-knocks from single/double knocks
- Handles mechanical bounce and sensor noise
- Uses `KnockSequence` for temporal pattern tracking
- Implements 1.5-second cooldown after successful detections
- Supports both accelerometer and gyroscope input streams

### 3. EjectionOrchestrator Agent
**Role**: System coordination and safe disk management
**Responsibilities**:
- Coordinates Time Machine backup handling
- Manages disk ejection workflows across multiple external volumes
- Provides volume-independent audio feedback
- Maintains system state synchronization

**Key Behaviors**:
- Intelligent state management with `LockedBox`
- Time Machine detection and graceful shutdown
- Safe disk mounting verification before ejection
- Audio level management for user feedback
- Robust error handling with fallback mechanisms

### 4. System Infrastructure Agents
**Role**: Supporting services and utilities
**Responsibilities**:
- LaunchDaemon management (always-on operation)
- Log management and error reporting
- Configuration management and persistence
- Resource monitoring and cleanup

**Key Behaviors**:
- Persistent operation with closed-lid support
- Comprehensive logging for debugging
- Graceful error recovery and restarts
- System resource management

## Agent Interaction Patterns

### Event-Driven Architecture
Agents communicate through a centralized event system:
1. **SPUAccelerometerService** → generates raw sensor data events
2. **TripleKnockDetector** → processes sensor events and emits knock detection events
3. **EjectionOrchestrator** → receives knock events and initiates ejection workflows

### State Synchronization
- **LockedBox** provides thread-safe shared state access
- Atomic operations prevent race conditions
- Cooldown mechanisms prevent over-reactivity

### Error Handling
- Hierarchical error reporting with detailed diagnostics
- Automatic recovery mechanisms
- Fallback behaviors for robustness

## Configuration and Personalization

### Adjustable Parameters
- **Detection sensitivity**: Adjust threshold for knock recognition
- **Grouping window**: Control timing between knocks
- **Cooldown period**: Prevent false positives
- **Audio settings**: Volume and sound preferences

### Time Machine Integration
- **Auto-detection**: System automatically detects running backups
- **Graceful shutdown**: 30-second timeout before force stop
- **State verification**: Confirms backup completion

## Performance Characteristics

### Resource Usage
- **CPU**: Minimal processing for pattern recognition
- **Memory**: Efficient data structures for sensor streams
- **Battery**: Optimized for background operation
- **Network**: No external dependencies

### Response Time
- **Sensor activation**: Immediate upon triple-knock detection
- **Disk ejection**: 1-3 seconds for complete process
- **State restoration**: Under 0.5 seconds
- **Audio feedback**: Real-time with proper volume management

## Safety Features

### Pre-Ejection Checks
- Time Machine status verification
- External disk mounting validation
- Sufficient free space verification
- System integrity checks

### Error Recovery
- **Ejection failures**: Detailed error logging and user notification
- **Time Machine failures**: Graceful degradation to manual intervention
- **Audio failures**: Fallback to system default sounds
- **State inconsistencies**: Automatic recovery and retry mechanisms

## Testing and Validation

### Automated Test Suite
- **Knock sequence tests**: Single, double, and triple knock recognition
- **Gyroscope integration tests**: Rotational impulse detection
- **Ejection planning tests**: Time Machine and disk handling workflows
- **State synchronization tests**: Thread safety and race condition prevention

### Performance Benchmarks
- **Startup time**: < 2 seconds
- **Sensor activation**: < 0.5 seconds
- **Knock detection**: < 0.1 seconds
- **Ejection completion**: < 3 seconds

## Deployment and Setup

### Installation
```bash
git clone https://github.com/nsd97/eject-different.git
cd eject-different
sudo Scripts/install.sh
```

### Configuration
- **System preferences**: Adjustable via `pmset` commands
- **LaunchDaemon**: Persistent operation with restart policies
- **Logging**: Comprehensive log files for troubleshooting

### Monitoring
- **Service status**: `launchctl print system/com.nsd97.eject-different`
- **Event logs**: `/var/log/eject-different.log`
- **Error logs**: `/var/log/eject-different.error.log`
- **System resources**: Monitor with standard macOS tools

## Future Enhancements

### Potential Improvements
- **Machine learning**: Adaptive pattern recognition
- **Multi-device support**: Integration with other sensor types
- **Cloud sync**: Backup of ejection history and preferences
- **Mobile notifications**: Push notifications for ejection events
- **Integration**: Compatibility with other automation systems

### Research Directions
- **Energy optimization**: Further power consumption reduction
- **Sensor fusion**: Enhanced accuracy through multiple sensor types
- **Edge computing**: Local processing capabilities
- **AI-driven patterns**: Intelligent learning of user habits

## Conclusion

Eject Different represents a sophisticated autonomous agent system that demonstrates:

- **Intelligent sensing**: Advanced pattern recognition from motion sensors
- **Cooperative behavior**: Multiple agents working in harmony
- **Resilient architecture**: Graceful error handling and recovery
- **User-centric design**: Minimal user interaction required
- **Production readiness**: Comprehensive testing and deployment infrastructure

The system exemplifies modern autonomous agent design principles, combining real-time data processing, state management, and orchestration to deliver a reliable and user-friendly disk ejection solution.