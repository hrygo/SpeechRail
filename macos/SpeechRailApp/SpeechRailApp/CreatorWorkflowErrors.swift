import Foundation
import Observation
import SpeechRailControlKit

enum CreatorWorkflowErrors {

    static func message(for error: Error) -> String {
        if let error = error as? CreatorCapabilityUnavailableError {
            return error.errorDescription ?? "当前连接未提供这项创作能力。"
        }
        if let workStoreError = error as? CreativeWorkStoreError {
            return switch workStoreError {
            case .invalidWorkID:
                "生成结果的作品标识无效，请重试"
            case .invalidTitle:
                "作品名称不能为空"
            case .workConflict:
                "作品库已有另一份同名标识的音频，未覆盖现有作品"
            case .storageUnavailable:
                "音频已生成，但本机作品库未能完成保存；请检查磁盘权限和可用空间后重试"
            case .recoveryRequired:
                "作品库需要先完成恢复，请重新打开我的作品后重试"
            case .audioUnavailable:
                "服务没有返回可保存音频，请检查服务状态后重试"
            }
        }
        if let error = error as? SpeechBindingUnavailableError {
            return error.errorDescription ?? "无法确认所选音色的当前版本，请刷新音色和服务信息后重试。"
        }
        guard let error = error as? ServiceAPIClientError else {
            return "创作服务暂时不可用"
        }
        switch error {
        case .invalidURL:
            return "创作服务地址无效，请检查服务状态"
        case .invalidResponse:
            return "创作服务返回了无法识别的结果，请运行诊断后重试"
        case .requestFailed:
            return "无法连接本机 SpeechRail 服务，请检查服务状态后重试"
        case .requestTimedOut:
            return "创作服务响应超时，请稍后重试"
        case .notModifiedWithoutCache:
            return "创作服务缓存已失效，请重新读取后重试"
        case .invalidContract:
            return "创作服务版本不匹配，请运行诊断后重试"
        case let .http(_, code, _, _, _):
            switch code {
            case "invalid_api_key":
                return "本机服务凭据不可用，请检查服务配置后重试"
            case "model_not_found":
                return "当前模型未在服务端登记，请到模型页核对模型目录"
            case "backend_not_ready":
                return "语音服务尚未就绪，请先检查服务状态"
            case "dependency_missing":
                return "语音服务依赖未就绪，请运行诊断后重试"
            case "voice_store_unavailable":
                return "音色库暂时不可用，请稍后重试"
            case "voice_in_use":
                return "该音色正在使用，暂时无法删除；停止相关任务后重试"
            case "voice_deletion_failed":
                return "音色删除未完成，请重试或打开诊断"
            case "voice_creation_failed":
                return "音色创建未完成，请检查输入后重试"
            case "voice_update_unsupported":
                return "该音色的来源或系统属性不可修改"
            case "voice_update_failed":
                return "音色修改未保存，请检查输入后重试"
            case "invalid_name":
                return "音色名称不能为空，请修改后重试"
            case "invalid_instruction":
                return "音色描述无效，请检查内容后重试"
            case "invalid_seed":
                return "采样种子无效，请填写 0–4294967295 之间的整数"
            case "invalid_ref_text":
                return "参考文案需要 20–240 个字符，请调整后重试"
            case "voice_not_found", "voice_not_available":
                return "所选音色当前不可用，请重新选择"
            case "clone_speed_unsupported":
                return "参考音色当前只支持 1.0x 语速"
            case "voice_preview_unsupported":
                return "当前档位不支持音色预览"
            case "voice_cloning_unsupported":
                return "当前档位未提供参考音色能力；请到模型管理查看服务公布的可用档位"
            case "voice_quality_reject":
                return "生成的参考音频未通过质量检查，请调整描述或参考文案后重试"
            case "voice_not_production_ready":
                return "该音色还没有通过配音效果检查。请到音色库点「检查配音效果」，通过后即可正式制作。"
            case "voice_validation_runtime_changed":
                return "检查期间服务重新加载了语音模型，本次结果已作废。请重新检查配音效果。"
            case "voice_validation_store_unavailable":
                return "音色验收记录暂时不可读，请检查服务状态后重试"
            case "voice_validation_runtime_unavailable":
                return "语音服务尚未就绪，无法确认音色当前可用性；请先检查服务状态"
            case "transcript_mismatch":
                return "生成音频与参考文案未能匹配，请调整参考文案后重试"
            case "transcription_unavailable":
                return "本地语音识别校验暂不可用，请检查服务状态后重试"
            case "output_invalid":
                return "服务生成的参考音频无效，请重试或打开诊断"
            case "audio_too_short":
                return "参考音频过短，请使用更完整的音频后重试"
            case "audio_too_long":
                return "参考音频过长，请缩短音频后重试"
            case "voice_reference_too_short":
                return "服务生成的参考音频过短，请调整描述或参考文案后重试"
            case "invalid_audio", "audio_decode_failed":
                return "参考音频无法识别，请检查文件格式后重试"
            case "empty_audio", "tts_audio_invalid":
                return "服务没有返回可播放音频，请检查服务状态后重试"
            case "queue_full", "backend_busy":
                return "语音资源正忙，请稍后重试"
            case "backend_timeout":
                return "语音处理超时，请重试"
            case "audio_encode_failed", "backend_error":
                return "音频生成失败，请重试"
            case "voice_design_unsupported":
                return "当前档位未提供音色创作能力，请到模型页核对当前档位"
            case "voice_design_unavailable":
                return "音色创作服务尚未就绪，请检查服务状态后重试"
            case "voice_design_validation_required", "voice_design_machine_validation_required":
                return "这次音色还没有完成复验，请重新保存并完成两项试听确认"
            case "voice_design_state_conflict", "voice_design_revision_conflict", "voice_design_publish_conflict":
                return "音色状态已经变化，请重新生成候选后再保存"
            case "voice_design_validation_not_found", "voice_design_candidate_not_found":
                return "候选音色已经过期，请重新生成候选"
            case "voice_design_target_in_use", "voice_already_exists":
                return "音色标识已存在，请换一个名称"
            default:
                return "创作服务暂时不可用"
            }
        }
    }

}
