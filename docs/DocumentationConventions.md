# Documentation & Issue Naming Conventions

> [!NOTE]
> **Currency Status:** Current as of June 2, 2026. Details the repository naming conventions and organizing principles established during the documentation consolidation for **Emojig v0.1.5**.

## 1. Overview

During the documentation consolidation phase of Emojig, the repository transitioned from unstructured file naming (a mix of snake_case, ALL_CAPS, and CamelCase) to a deliberate, hybrid naming strategy. 

This document captures the decisions, pros, cons, and maintenance expectations of this architectural choice.

---

## 2. Naming Standards by Directory

The repository separates high-level reference documentation from point-in-time issue write-ups using two distinct naming conventions:

| Directory | Convention | Example | Purpose |
|-----------|------------|---------|---------|
| `docs/` | **PascalCase.md** | `PlatformSupport.md`, `InlineTui.md` | Evergreen developer guides, references, manuals, and design patterns. |
| `issues/` | **Numbered dash-case (kebab-case)** | `01-config-file-silent-truncation.md` | Point-in-time bug investigations, proposed feature specifications, and topics. |

---

## 3. Rationale & Learnings

### A. Semantic Context at a Glance
By utilizing distinct naming styles, developers scanning the repository or reading markdown links immediately gain visual context:
* A link to `docs/InlineTui.md` indicates a permanent, authoritative design manual.
* A link to `issues/06-vt-copy-paste-and-output-modes.md` indicates a specific technical exploration or historical issue resolution.

### B. Directory-Specific Optimization
* **PascalCase in `docs/`** aligns with clean structural documentation, presenting the files as formal, high-level modules of the project's permanent library.
* **Numbered Kebab-Case in `issues/`** is optimized for searchability and chronology. The sequential prefix (`01-`, `02-`) solves the problem of issues being scattered alphabetically, preserving their logical or chronological progression, while kebab-case is extremely readable for longer descriptive phrases.

### C. Maintenance Trade-offs
* **Trade-off:** The only drawback is that the file naming is not 100% globally uniform across the entire repository. A developer creating a new file must pay attention to the specific directory rules rather than applying a single repository-wide standard.
* **Decision:** The visual clarity, semantic separation, and chronological order of issues far outweigh the minor cognitive load of using two distinct conventions.
