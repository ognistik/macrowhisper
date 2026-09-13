/**
 * Public store contract used by the editor.  Keeping the re-export in the
 * store directory gives UI code a stable import that does not couple it to
 * the model module's other fixture types.
 */
export type { EditorStore } from '../model/types'
export { EditorStoreError, isEditorStoreError } from '../model/types'

