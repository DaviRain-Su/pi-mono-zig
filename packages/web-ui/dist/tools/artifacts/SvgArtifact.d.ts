import { ArtifactElement } from "./ArtifactElement.js";
export declare class SvgArtifact extends ArtifactElement {
    filename: string;
    private _content;
    private previewUrl;
    get content(): string;
    set content(value: string);
    private viewMode;
    protected createRenderRoot(): HTMLElement | DocumentFragment;
    private setViewMode;
    private revokePreviewUrl;
    private updatePreviewUrl;
    getHeaderButtons(): import("lit-html").TemplateResult<1>;
    connectedCallback(): void;
    disconnectedCallback(): void;
    render(): import("lit-html").TemplateResult<1>;
}
declare global {
    interface HTMLElementTagNameMap {
        "svg-artifact": SvgArtifact;
    }
}
//# sourceMappingURL=SvgArtifact.d.ts.map