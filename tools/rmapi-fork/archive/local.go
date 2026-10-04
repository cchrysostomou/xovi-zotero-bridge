package archive

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/juruen/rmapi/encoding/rm"
)

// ReadFromDir populates a Zip by reading a document's files directly from
// its on-device xochitl directory layout, instead of from a zip archive
// downloaded from the reMarkable cloud. This allows annotation merging to
// run entirely locally against files already present on the tablet, since
// xochitl stores exactly the same pieces (<uuid>.content, <uuid>.<fileType>,
// <uuid>/<page>.rm) that a cloud-fetched archive would contain.
//
// Unlike Read(), this does not require or use .pagedata or thumbnails: the
// annotation-merge logic in the annotations package only consumes Content,
// Payload, and per-page rm.Rm data.
func (z *Zip) ReadFromDir(dir, uuid string) error {
	contentPath := filepath.Join(dir, uuid+".content")
	contentBytes, err := os.ReadFile(contentPath)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(contentBytes, &z.Content); err != nil {
		return err
	}
	z.UUID = uuid

	z.buildPageMapFromContent()

	if z.Content.PageCount <= 0 && len(z.Pages) == 0 {
		return nil
	}

	if err := z.readLocalPayload(dir, uuid); err != nil {
		return err
	}

	if err := z.readLocalData(dir, uuid); err != nil {
		return err
	}

	return nil
}

// readLocalPayload reads the <uuid>.<fileType> file (e.g. the original PDF)
// from the document's directory, if the document has one (notebooks with no
// backing PDF simply have no payload).
func (z *Zip) readLocalPayload(dir, uuid string) error {
	ext := z.Content.FileType
	if ext == "" {
		return nil
	}

	payloadPath := filepath.Join(dir, uuid+"."+ext)
	payload, err := os.ReadFile(payloadPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	z.Payload = payload
	return nil
}

// readLocalData reads per-page .rm annotation files from the document's
// <uuid>/ directory. Files that don't resolve to a known page (such as
// xochitl's penLayers.rm, toc.rm, or rm-linkFromSelection.rm helper files)
// are silently skipped, matching how the zip-based reader only recognizes
// page-indexed or page-uuid-indexed .rm entries.
func (z *Zip) readLocalData(dir, uuid string) error {
	pageDir := filepath.Join(dir, uuid)
	entries, err := os.ReadDir(pageDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(name, ".rm") {
			continue
		}
		namePart := strings.TrimSuffix(name, ".rm")

		idx, ok := z.localPageIndex(namePart)
		if !ok {
			// Not a recognized/live page (e.g. penLayers.rm, toc.rm, or a
			// page UUID that was deleted and excluded from the page map).
			continue
		}
		if idx < 0 || len(z.Pages) <= idx {
			continue
		}

		raw, err := os.ReadFile(filepath.Join(pageDir, name))
		if err != nil {
			return err
		}

		page := rm.New()
		if err := page.UnmarshalBinary(raw); err != nil {
			return err
		}
		z.Pages[idx].Data = page
	}

	return nil
}

// localPageIndex resolves a page filename stem (either a legacy numeric
// index or a page UUID) to its page slice index, returning ok=false for
// anything not present in the page map (auxiliary xochitl files like
// penLayers.rm/toc.rm, or deleted pages excluded from the map). This
// intentionally does not reuse pageIndex(), whose zero-value/no-error
// return for an unmapped-but-valid UUID would otherwise be misread as
// "page 0" here.
func (z *Zip) localPageIndex(namePart string) (int, bool) {
	if idx, err := strconv.Atoi(namePart); err == nil {
		return idx, true
	}
	if _, err := uuid.Parse(namePart); err != nil {
		return -1, false
	}
	if z.pageMap == nil {
		return -1, false
	}
	idx, ok := z.pageMap[namePart]
	return idx, ok
}
