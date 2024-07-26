//
//  RNWebrtcVad.swift
//  RNWebrtcVad
//
//  Created by Jerry Su on 2024/7/25.
//

import Foundation
import AVFAudio

func Log(_ message: String) {
    print("[WebRTCVad] \(message)")
}

@objc(RNWebrtcVad)
class RNWebrtcVad: RCTEventEmitter {
    var hasListeners: Bool = false
    var cumulativeProcessedSampleLengthMs: Double = 0
    var voiceDetector: VoiceActivityDetector!
    
    var audioData: Data = Data()
    var cumulativeAudioData: Data = Data()
    
    override func supportedEvents() -> [String]? {
        return ["RNWebrtcVad_SpeakingUpdate"]
    }

    // Will be called when this module's first listener is added.
    override func startObserving() {
        hasListeners = true
    }

    // Will be called when this module's last listener is removed, or on dealloc.
    override func stopObserving() {
        hasListeners = false
    }
    
    override static func requiresMainQueueSetup() -> Bool {
        return false
    }
    
    @objc func start(_ options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let mode = options["mode"] as? Int32 ?? 0
        let preferredBufferSize = options["preferredBufferSize"] as? Int32 ?? -1
        Log("Start recording, mode: \(mode)")
        
        voiceDetector = VoiceActivityDetector(mode: mode)
        let inputController: AudioInputController! = AudioInputController.sharedInstance()
        
        inputController.delegate = self
        
        // If not specified, will match HW sample, which could be too high.
        // Ex: Most devices run at 48000,41000 (or 48kHz/44.1hHz). So cap at highest vad supported sample rate supported
        // See: https://github.com/TeamGuilded/react-native-webrtc-vad/blob/master/webrtc/common_audio/vad/include/webrtc_vad.h#L75
        inputController.prepare(withSampleRate: 16000, preferredBufferSize: preferredBufferSize)
        
        audioData.removeAll()
        cumulativeAudioData.removeAll()
        
        let status = inputController.start()
        if (status != noErr) {
            reject("\(status)", "Failed to start audio input controller", nil)
        } else {
            resolve(nil)
        }
    }
    
    @objc func stop(_ discard: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        Log("Stop recording, discard: \(discard)")
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let fileURL = cacheDir.appendingPathComponent("vad.pcm")
        
        var writeErrorMessage: String?
        if (!discard) {
            do {
                try cumulativeAudioData.write(to: fileURL, options: [])
                Log("Write file to \(fileURL)")
            } catch {
                Log("Failed to write file: \(error)")
                writeErrorMessage = error.localizedDescription
            }
        }
        
        AudioInputController.sharedInstance().stop()
        voiceDetector = nil
        audioData.removeAll()
        cumulativeAudioData.removeAll()
        if !discard {
            if let errMsg = writeErrorMessage {
                reject(nil, errMsg, nil)
            } else {
                let filePath = fileURL.absoluteString.replacingOccurrences(of: "file://", with: "")
                resolve(filePath)
            }
        } else {
            resolve(nil)
        }
    }
    
    @objc func audioDeviceSettings(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let audioSession = AVAudioSession.sharedInstance()
        
        let bufferSize = audioSession.ioBufferDuration * audioSession.sampleRate
        let hwSampleRate = audioSession.sampleRate
        
        resolve(["bufferSize": bufferSize, "hwSampleRate": hwSampleRate])
    }
}

extension RNWebrtcVad: AudioInputControllerDelegate {
    func processSampleData(_ data: Data!) {
        audioData.append(data)
        cumulativeAudioData.append(data)
        
        let sampleRate = AudioInputController.sharedInstance().audioSampleRate
        
        let sampleLengthMs = 0.02
        cumulativeProcessedSampleLengthMs += (Double(data.count) / sampleRate)
        let chunkSizeBytes = sampleLengthMs * sampleRate * 2
        
        if audioData.count >= Int(chunkSizeBytes) {
            let audioSample = audioData.withUnsafeBytes {
                Array($0.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
            }
            
            let isVoice = voiceDetector.isVoice(audioSample, sample_rate: Int32(sampleRate), length: Int32(chunkSizeBytes/2))
            audioData.removeAll()
            
            // Sends updates ~140ms apart back to listeners
            // This was chosen from some basic testing/tuning. At 20ms samples, we didn't wanna be
            // sending events over the react native bridge so often, as it's too frequent/not useful.
            // If we made it much longer (>=200ms) the delay of the speaking would be quite pronounced to the user.
            // So 140ms was the nice medium
            let eventInterval = 0.140
            if (cumulativeProcessedSampleLengthMs >= eventInterval) {
                cumulativeProcessedSampleLengthMs = 0
                
                let isSpeaking = isVoice == 1
                sendEvent(withName: "RNWebrtcVad_SpeakingUpdate", body: ["isVoice": isSpeaking])
            }
        }
    }
}
