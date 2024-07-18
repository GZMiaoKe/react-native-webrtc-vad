
package com.guilded.gg;

import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.facebook.soloader.SoLoader;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;

public class RNWebrtcVadModule extends ReactContextBaseJavaModule implements AudioInputController.AudioInputControllerListener {

    private final ReactApplicationContext reactContext;
    private double cumulativeProcessedSampleLengthMs = 0;
    private short[] audioData;
    private String filePath;
    private int audioDataOffset;

    private static boolean disableInputController = false;

    public RNWebrtcVadModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }

    // Native methods
    static {
        SoLoader.loadLibrary("voice-activity-detector");
    }

    private static native void initializeVad(int mode);

    private static native void stopVad();

    private static native boolean isVoice(short[] audioFrame, int sampleRate, int frameLength);


    @Override
    public String getName() {
        return "RNWebrtcVad";
    }

    @ReactMethod
    public void start(ReadableMap options, Promise promise) {
        Log.d(getName(), "Starting");

        int mode = 0;
        int preferredBufferSize = -1;

        if (options != null) {
            if (options.hasKey("mode")) {
                mode = options.getInt("mode");
            }

            if (options.hasKey("preferredBufferSize")) {
                preferredBufferSize = options.getInt("preferredBufferSize");
            }
        }

        // set file path to "vad.pcm" in cache directory
        filePath = reactContext.getCacheDir().getAbsolutePath() + "/vad.pcm";
        // if file exists, delete it
        File file = new File(filePath);
        if (file.exists()) {
            file.delete();
        }

        RNWebrtcVadModule.initializeVad(mode);
        final AudioInputController inputController = AudioInputController.getInstance();

        // If not specified, will match HW sample, which could be too high.
        // Ex: Most devices run at 48000,41000 (or 48kHz/44.1hHz). So cap at highest vad supported sample rate supported
        // See: https://github.com/TeamGuilded/react-native-webrtc-vad/blob/master/webrtc/common_audio/vad/include/webrtc_vad.h#L75
        inputController.prepareWithSampleRate(16000, preferredBufferSize);

        if (!this.disableInputController) {
            inputController.setAudioInputControllerListener(this);
            inputController.start();
        } else {
            Log.d(getName(), "Internal audio recorder input controller disabled. You must manually call onProcessSampleData");
        }

        promise.resolve(null);
    }

    @ReactMethod
    public void stop(Promise promise) {
        promise.resolve(this.stopVAD());
    }

    @ReactMethod
    public void addListener(String eventName) {
        // Keep this method here for compatibility with the JS side
    }

    @ReactMethod
    public void removeListeners(int count) {
        // Keep this method here for compatibility with the JS side
    }

    private String stopVAD() {
        if (BuildConfig.DEBUG) {
            Log.d(getName(), "Stopping");
        }

        RNWebrtcVadModule.stopVad();
        AudioInputController inputController = AudioInputController.getInstance();
        inputController.stop();
        inputController.setAudioInputControllerListener(null);
        audioData = null;
        String path = filePath;
        filePath = null;
        return path;
    }

    @ReactMethod
    public void audioDeviceSettings(Promise promise) {
        try {
            final AudioInputController inputController = AudioInputController.getInstance();
            WritableMap settings = Arguments.createMap();

            settings.putDouble("hwSampleRate", inputController.sampleRate());
            settings.putDouble("bufferSize", inputController.bufferSize());

            promise.resolve(settings);
        }
        catch(Exception error) {
            Log.d(getName(), "reporting audio device settings failed: " + error);
            promise.reject(error);
        }
    }

    public void setDisableAudioInputController(boolean disableAudioInputController){
        this.disableInputController = disableAudioInputController;
    }

    @Override
    public void onProcessingError(String error){
        if (BuildConfig.DEBUG) {
            Log.d(getName(), "Audio sample processing error. Stopping VAD: " + error);
        }
        stopVAD();
    }

    @Override
    public void onProcessSampleData(ByteBuffer data) {
        final AudioInputController inputController = AudioInputController.getInstance();
        int sampleRate = inputController.sampleRate();

        // Google recommends sending samples (in 10ms, 20, or 30ms) chunk.
        // See: https://github.com/TeamGuilded/react-native-webrtc-vad/blob/master/webrtc/common_audio/vad/include/webrtc_vad.h#L75

        double sampleLengthMs = 0.02;

        cumulativeProcessedSampleLengthMs += sampleLengthMs;
        int chunkSize = (int) (sampleLengthMs /* seconds/chunk */ * sampleRate * 2.0); /* bytes/sample */
        ; /* bytes/chunk */


        if (audioData == null) {
            audioData = new short[chunkSize];
        }

        int remainingFrames = audioData.length - audioDataOffset;

        if (remainingFrames > 0) {
            ShortBuffer audioDataBuffer = data.asShortBuffer();
            int framesToRead = audioDataBuffer.remaining() < remainingFrames ? audioDataBuffer.remaining() : remainingFrames;
            audioDataBuffer.get(audioData, audioDataOffset, framesToRead);
            audioDataOffset += framesToRead;
        }


        if (audioDataOffset == audioData.length) {
            audioDataOffset = 0;

            // append data to file (little endian)
            try {
              File file = new File(filePath);
              if (!file.exists()) {
                file.createNewFile();
              }
              FileOutputStream fos = new FileOutputStream(file, true);
              for (int i = 0; i < audioData.length; i++) {
                fos.write(audioData[i] & 0xff);
                fos.write((audioData[i] >> 8) & 0xff);
              }
              fos.close();
            } catch (Exception e) {
              e.printStackTrace();
            }



            boolean isVoice = isVoice(audioData, sampleRate, chunkSize / 2);

            // Sends updates ~140ms apart back to listeners
            // This was chosen from some basic testing/tuning. At 20ms samples, we didn't wanna be
            // sending events over the react native bridge so often, as it's too frequent/not useful.
            // If we made it much longer (>=200ms) the delay of the speaking would be quite pronounced to the user.
            // So 140ms was the nice medium
            double eventInterval = 0.140;
            if (cumulativeProcessedSampleLengthMs >= eventInterval) {
                cumulativeProcessedSampleLengthMs = 0;

                if (BuildConfig.DEBUG) {
                    Log.d(getName(), "Sample buffer filled + analyzed: " + isVoice);
                }

                // Create map for params
                WritableMap payload = Arguments.createMap();
                payload.putBoolean("isVoice", isVoice);
                reactContext
                        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                        .emit("RNWebrtcVad_SpeakingUpdate", payload);
            }
        }

    }

}
