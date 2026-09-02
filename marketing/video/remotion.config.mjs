/**
 * Renderer settings.
 *
 * H.264 in an MP4 because every place this goes — X, Product Hunt, the site —
 * takes that and re-encodes it anyway; handing them anything more exotic just
 * adds a conversion nobody sees the result of.
 */
import { Config } from '@remotion/cli/config'

Config.setVideoImageFormat('jpeg')
Config.setCodec('h264')
Config.setEntryPoint('./src/index.js')
