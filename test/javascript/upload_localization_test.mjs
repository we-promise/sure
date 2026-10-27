import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

async function loadController(name) {
  const source = (await readFile(new URL(`../../app/javascript/controllers/${name}_controller.js`, import.meta.url), "utf8"))
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}");
  return (await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)).default;
}
const AttachmentController = await loadController("attachment_upload");
const FileController = await loadController("file_upload");
const DragController = await loadController("drag_and_drop_import");

function element(hidden = false) {
  const classes = new Set(hidden ? ["hidden"] : []);
  return {
    textContent: "", disabled: false,
    classList: { add: (value) => classes.add(value), remove: (value) => classes.delete(value), contains: (value) => classes.has(value) },
    set innerHTML(_) { throw new Error("Labels and file names must remain text"); },
  };
}
function attachment(files = []) {
  const controller = new AttachmentController();
  controller.fileInputTarget = { files };
  controller.maxFilesValue = 5;
  controller.maxSizeValue = 2 * 1024 * 1024;
  controller.labelsValue = {
    upload: "上传", too_many_files: "最多可选 5 个文件", file_too_large: "单个文件最大为 2 MB",
    upload_files: { 1: "Загрузить 1 файл", 2: "Загрузить 2 файла", 3: "Загрузить 3 файла", 4: "Загрузить 4 файла", 5: "Загрузить 5 файлов" },
  };
  controller.submitButtonTarget = element();
  controller.hasUploadTextTarget = controller.hasFileNameTarget = true;
  controller.uploadTextTarget = element();
  controller.fileNameTarget = element(true);
  controller.fileNameText = element();
  controller.fileNameTarget.querySelector = () => controller.fileNameText;
  return controller;
}
const file = (name = "synthetic.txt", size = 1) => ({ name, size });

test("empty attachment selection has translated disabled upload action", () => {
  const controller = attachment();
  controller.updateSubmitButton();
  assert.equal(controller.submitButtonTarget.textContent, "上传");
  assert.equal(controller.submitButtonTarget.disabled, true);
  assert.equal(controller.uploadTextTarget.classList.contains("hidden"), false);
  assert.equal(controller.fileNameTarget.classList.contains("hidden"), true);
});

test("attachment counts use server-selected plural labels and preserve filename text", () => {
  for (const count of [1, 2, 5]) {
    const files = Array.from({ length: count }, (_, i) => file(`<img src=x onerror=alert(1)> O'Brien $& ${i}.pdf`));
    const controller = attachment(files);
    controller.updateSubmitButton();
    assert.equal(controller.submitButtonTarget.textContent, controller.labelsValue.upload_files[count]);
    assert.equal(controller.submitButtonTarget.disabled, false);
    assert.equal(controller.fileNameText.textContent, files.map((item) => item.name).join(", "));
    assert.equal(controller.fileNameTarget.classList.contains("hidden"), false);
    assert.equal(controller.uploadTextTarget.classList.contains("hidden"), true);
  }
});

test("attachment count limit is unchanged and uses translated error", () => {
  const controller = attachment(Array.from({ length: 6 }, () => file()));
  controller.updateSubmitButton();
  assert.equal(controller.submitButtonTarget.disabled, true);
  assert.equal(controller.submitButtonTarget.textContent, controller.labelsValue.too_many_files);
});

test("attachment byte limit and existing size-error priority are unchanged", () => {
  const controller = attachment([file("exact.pdf", 2 * 1024 * 1024)]);
  controller.updateSubmitButton();
  assert.equal(controller.submitButtonTarget.disabled, false);
  controller.fileInputTarget.files = Array.from({ length: 6 }, () => file("large.pdf", 2 * 1024 * 1024 + 1));
  controller.updateSubmitButton();
  assert.equal(controller.submitButtonTarget.disabled, true);
  assert.equal(controller.submitButtonTarget.textContent, controller.labelsValue.file_too_large);
  controller.fileInputTarget.files = [];
  controller.updateSubmitButton();
  assert.equal(controller.submitButtonTarget.textContent, controller.labelsValue.upload);
});

test("upload progress interpolates the original filename literally as text", () => {
  const controller = new FileController();
  const filename = '<img src=x> $& $` $\' %{filename} 文件.csv';
  controller.uploadingValue = "正在上传 %{filename}…";
  controller.hasInputTarget = controller.hasFileNameTarget = controller.hasUploadAreaTarget = true;
  controller.inputTarget = { files: [file(filename)] };
  const text = element();
  const icon = element();
  controller.fileNameTarget = { querySelector: (selector) => selector === "p" ? text : icon };
  controller.uploadAreaTarget = element();
  controller.formSubmitting();
  assert.equal(text.textContent, `正在上传 ${filename}…`);
  assert.equal(icon.classList.contains("animate-pulse"), true);
  assert.equal(controller.uploadAreaTarget.classList.contains("opacity-70"), true);
});

function drag(files) {
  const controller = new DragController();
  controller.invalidFileTypeValue = "Tipo di file non valido. Carica un file CSV.";
  controller.extensionsValue = ["csv"];
  controller.overlayTarget = element();
  controller.inputTarget = { files: [] };
  controller.submits = 0;
  controller.formTarget = { requestSubmit: () => controller.submits++ };
  controller.dragDepth = 2;
  return { controller, event: { dataTransfer: { files }, preventDefault() {} } };
}

test("invalid CSV drop uses translated alert without submitting or assigning files", () => {
  const { controller, event } = drag([{ name: "synthetic.pdf", type: "application/pdf" }]);
  const alerts = [];
  const previousAlert = globalThis.alert;
  globalThis.alert = (message) => alerts.push(message);
  try { controller.drop(event); } finally { globalThis.alert = previousAlert; }
  assert.deepEqual(alerts, [controller.invalidFileTypeValue]);
  assert.equal(controller.submits, 0);
  assert.deepEqual(controller.inputTarget.files, []);
  assert.equal(controller.dragDepth, 0);
  assert.equal(controller.overlayTarget.classList.contains("hidden"), true);
});

test("CSV MIME or filename acceptance stays unchanged and keeps the original file list", () => {
  for (const item of [{ name: "synthetic.txt", type: "text/csv" }, { name: "synthetic.CSV", type: "" }]) {
    const { controller, event } = drag([item]);
    controller.drop(event);
    assert.equal(controller.submits, 1);
    assert.equal(controller.inputTarget.files, event.dataTransfer.files);
  }
});


test("configured QIF drops work without allowing CSV when it is not configured", () => {
  const { controller, event } = drag([{ name: "synthetic.QIF", type: "" }]);
  controller.extensionsValue = ["qif"];
  controller.drop(event);
  assert.equal(controller.submits, 1);
  const csv = drag([{ name: "synthetic.txt", type: "text/csv" }]);
  csv.controller.extensionsValue = ["qif"];
  const previousAlert = globalThis.alert;
  globalThis.alert = () => {};
  try { csv.controller.drop(csv.event); } finally { globalThis.alert = previousAlert; }
  assert.equal(csv.controller.submits, 0);
});
