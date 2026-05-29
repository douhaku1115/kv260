#!/usr/bin/env python3
"""YOLOv7 VOC inference on KV260 DPU"""
import sys
import time
import numpy as np
import cv2
import xir
import vart

VOC_CLASSES = [
    "aeroplane","bicycle","bird","boat","bottle","bus","car","cat",
    "chair","cow","diningtable","dog","horse","motorbike","person",
    "pottedplant","sheep","sofa","train","tvmonitor"
]

ANCHORS = [
    [[12,16], [19,36], [40,28]],
    [[36,75], [76,55], [72,146]],
    [[142,110], [192,243], [459,401]]
]
STRIDES = [8, 16, 32]
NUM_CLASSES = 20

def preprocess(image_path, input_shape):
    h, w = input_shape
    img = cv2.imread(image_path)
    if img is None:
        print(f"Error: cannot read {image_path}")
        sys.exit(1)
    orig = img.copy()
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    img = cv2.resize(img, (w, h))
    img = img.astype(np.float32) / 255.0
    return img, orig

def sigmoid(x):
    x = np.clip(x, -50, 50)
    return 1.0 / (1.0 + np.exp(-x))

def decode_outputs(output_data, img_size=640, conf_thresh=0.25):
    boxes = []
    for idx, out in enumerate(output_data):
        stride = STRIDES[idx]
        anchor = ANCHORS[idx]
        out = out[0]
        grid_h, grid_w, _ = out.shape
        out = out.reshape(grid_h, grid_w, 3, NUM_CLASSES + 5)

        for ay in range(grid_h):
            for ax in range(grid_w):
                for a in range(3):
                    det = out[ay, ax, a]
                    obj_conf = sigmoid(det[4])
                    if obj_conf < conf_thresh:
                        continue
                    cls_scores = sigmoid(det[5:])
                    cls_id = np.argmax(cls_scores)
                    score = obj_conf * cls_scores[cls_id]
                    if score < conf_thresh:
                        continue
                    cx = (sigmoid(det[0]) * 2 - 0.5 + ax) * stride
                    cy = (sigmoid(det[1]) * 2 - 0.5 + ay) * stride
                    w = (sigmoid(det[2]) * 2) ** 2 * anchor[a][0]
                    h = (sigmoid(det[3]) * 2) ** 2 * anchor[a][1]
                    x1 = cx - w / 2
                    y1 = cy - h / 2
                    x2 = cx + w / 2
                    y2 = cy + h / 2
                    boxes.append([x1, y1, x2, y2, score, cls_id])
    return boxes

def nms(boxes, iou_thresh=0.45):
    if not boxes:
        return []
    boxes = np.array(boxes)
    keep = []
    order = boxes[:, 4].argsort()[::-1]
    while len(order) > 0:
        i = order[0]
        keep.append(i)
        if len(order) == 1:
            break
        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])
        w = np.maximum(0, xx2 - xx1)
        h = np.maximum(0, yy2 - yy1)
        inter = w * h
        area_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        area_o = (boxes[order[1:], 2] - boxes[order[1:], 0]) * (boxes[order[1:], 3] - boxes[order[1:], 1])
        iou = inter / (area_i + area_o - inter + 1e-6)
        inds = np.where(iou <= iou_thresh)[0]
        order = order[inds + 1]
    return boxes[keep]

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 yolov7_inference.py <xmodel> <image>")
        sys.exit(1)

    xmodel_path = sys.argv[1]
    image_path = sys.argv[2]

    graph = xir.Graph.deserialize(xmodel_path)
    subgraphs = graph.get_root_subgraph().toposort_child_subgraph()
    dpu_subgraphs = [s for s in subgraphs if s.has_attr("device") and s.get_attr("device") == "DPU"]
    runner = vart.Runner.create_runner(dpu_subgraphs[0], "run")

    input_tensors = runner.get_input_tensors()
    output_tensors = runner.get_output_tensors()
    in_shape = input_tensors[0].dims
    h, w = in_shape[1], in_shape[2]
    print(f"Input shape: {in_shape}")
    for i, ot in enumerate(output_tensors):
        print(f"Output[{i}] shape: {ot.dims}, fixpos: {ot.get_attr('fix_point')}")

    img, orig = preprocess(image_path, (h, w))

    input_data = [np.expand_dims(img, axis=0)]
    output_data = [np.empty(ot.dims, dtype=np.float32) for ot in output_tensors]

    start = time.time()
    job_id = runner.execute_async(input_data, output_data)
    runner.wait(job_id)
    elapsed = time.time() - start
    print(f"Inference time: {elapsed*1000:.1f} ms")

    boxes = decode_outputs(output_data, img_size=w, conf_thresh=0.25)
    detections = nms(boxes, iou_thresh=0.45)
    print(f"Detections: {len(detections)}")

    orig_h, orig_w = orig.shape[:2]
    for det in detections:
        x1 = int(det[0] / w * orig_w)
        y1 = int(det[1] / h * orig_h)
        x2 = int(det[2] / w * orig_w)
        y2 = int(det[3] / h * orig_h)
        x1, y1 = max(0, x1), max(0, y1)
        x2, y2 = min(orig_w, x2), min(orig_h, y2)
        score = det[4]
        cls_id = int(det[5])
        label = VOC_CLASSES[cls_id] if cls_id < len(VOC_CLASSES) else str(cls_id)
        print(f"  {label}: {score:.3f} [{x1},{y1},{x2},{y2}]")
        cv2.rectangle(orig, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(orig, f"{label} {score:.2f}", (x1, y1-5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

    output_path = image_path.rsplit('.', 1)[0] + "_result.jpg"
    cv2.imwrite(output_path, orig)
    print(f"Result saved to {output_path}")

if __name__ == "__main__":
    main()
