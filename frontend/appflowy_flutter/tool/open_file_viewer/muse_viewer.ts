import { createViewer } from '../../../../../../../vendors/open-file-viewer/packages/core/src/viewer.ts';
import { imagePlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/image.ts';
import { pdfPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/pdf.ts';
import { textPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/text.ts';
import { audioPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/audio.ts';
import { videoPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/video.ts';
import { officePlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/office.ts';
import { archivePlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/archive.ts';
import { epubPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/epub.ts';
import { xpsPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/xps.ts';
import { fallbackPlugin } from '../../../../../../../vendors/open-file-viewer/packages/core/src/plugins/fallback.ts';
import type { FileViewer } from '../../../../../../../vendors/open-file-viewer/packages/core/src/types.ts';
import '../../../../../../../vendors/open-file-viewer/packages/core/src/style.css';

declare global {
  interface Window {
    MuseViewer: { open(input: MuseOpenInput): Promise<void> };
    MuseViewerBridge?: { postMessage(value: string): void };
  }
}

interface MuseOpenInput {
  name: string;
  mime: string;
  base64: string;
  line?: number;
}

const root = document.querySelector<HTMLElement>('#viewer');
if (!root) throw new Error('viewer root missing');
let viewer: FileViewer | undefined;

const reply = (value: Record<string, unknown>) =>
  window.MuseViewerBridge?.postMessage(JSON.stringify(value));

const decode = (value: string): Uint8Array => {
  const raw = atob(value);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
  return bytes;
};

window.MuseViewer = {
  async open(input) {
    try {
      viewer?.destroy();
      const file = new File([decode(input.base64)], input.name, { type: input.mime });
      viewer = createViewer({
        container: root,
        file,
        fileName: input.name,
        mimeType: input.mime,
        width: '100%',
        height: '100%',
        fit: 'contain',
        theme: 'dark',
        toolbar: true,
        initialPage: input.line,
        plugins: [
          imagePlugin(),
          audioPlugin(),
          videoPlugin(),
          officePlugin({
            pdf: {
              workerSrc: './pdf.worker.mjs',
              cMapUrl: './cmaps/',
              standardFontDataUrl: './standard_fonts/',
              webFallbackScripts: 'never',
              useSystemFonts: true,
            },
          }),
          pdfPlugin({
            workerSrc: './pdf.worker.mjs',
            cMapUrl: './cmaps/',
            standardFontDataUrl: './standard_fonts/',
            webFallbackScripts: 'never',
            useSystemFonts: true,
          }),
          epubPlugin(),
          xpsPlugin(),
          archivePlugin(),
          textPlugin(),
          fallbackPlugin(),
        ],
        onLoad() { reply({ type: 'viewer.ready', engine: 'open-file-viewer' }); },
        onError(error) { reply({ type: 'viewer.error', message: error.message }); },
      });
    } catch (error) {
      reply({ type: 'viewer.error', message: error instanceof Error ? error.message : String(error) });
    }
  },
};

window.addEventListener('beforeunload', () => viewer?.destroy());
