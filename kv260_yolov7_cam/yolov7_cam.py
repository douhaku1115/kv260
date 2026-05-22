#!/usr/bin/env python3
"""YOLOv7 real-time camera inference on KV260 DPU"""
import sys
import time
import threading
import numpy as np
import cv2
import xir
import vart

COCO_CLASSES = [
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
    "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
    "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
    "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
    "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
    "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
    "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair",
    "couch","potted plant","bed","dining table","toilet","tv","laptop","mouse",
    "remote","keyboard","cell phone","microwave","oven","toaster","sink",
    "refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"
]

ANCHORS = [
    [[12,16], [19,36], [40,28]],
    [[36,75], [76,55], [72,146]],
    [[142,110], [192,243], [459,401]]
]
STRIDES = [8, 16, 32]

def decode_outputs(output_data, img_size=640, conf_thresh=0.25):
    all_boxes = []
    for idx, out in enumerate(output_data):
        stride = STRIDES[idx]
        anchor = np.array(ANCHORS[idx], dtype=np.float32)
        out = out[0]
        grid_h, grid_w, _ = out.shape
        out = out.reshape(grid_h, grid_w, 3, 85)
        raw_obj = out[..., 4]
        raw_thresh = np.log(conf_thresh / (1.0 - conf_thresh))
        mask = raw_obj > raw_thresh
        if not np.any(mask):
            continue
        ays, axs, ans = np.where(mask)
        det = out[ays, axs, ans]
        obj_conf = 1.0 / (1.0 + np.exp(-np.clip(det[:, 4], -50, 50)))
        cls_raw = np.clip(det[:, 5:], -50, 50)
        cls_scores = 1.0 / (1.0 + np.exp(-cls_raw))
        cls_id = np.argmax(cls_scores, axis=1)
        cls_max = cls_scores[np.arange(len(cls_id)), cls_id]
        scores = obj_conf * cls_max
        keep = scores > conf_thresh
        if not np.any(keep):
            continue
        ays, axs, ans = ays[keep], axs[keep], ans[keep]
        det = det[keep]
        scores = scores[keep]
        cls_id = cls_id[keep]
        sxy = 1.0 / (1.0 + np.exp(-np.clip(det[:, :2], -50, 50)))
        swh = 1.0 / (1.0 + np.exp(-np.clip(det[:, 2:4], -50, 50)))
        cx = (sxy[:, 0] * 2 - 0.5 + axs) * stride
        cy = (sxy[:, 1] * 2 - 0.5 + ays) * stride
        w = (swh[:, 0] * 2) ** 2 * anchor[ans, 0]
        h = (swh[:, 1] * 2) ** 2 * anchor[ans, 1]
        x1 = cx - w / 2
        y1 = cy - h / 2
        x2 = cx + w / 2
        y2 = cy + h / 2
        result = np.column_stack([x1, y1, x2, y2, scores, cls_id.astype(np.float32)])
        all_boxes.append(result)
    if not all_boxes:
        return np.empty((0, 6))
    return np.vstack(all_boxes)

def nms(boxes, iou_thresh=0.45):
    if len(boxes) == 0:
        return np.empty((0, 6))
    if not isinstance(boxes, np.ndarray):
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

class CameraThread:
    def __init__(self, camera_id):
        self.cap = cv2.VideoCapture(camera_id)
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        self.frame = None
        self.ret = False
        self.lock = threading.Lock()
        self.running = True
        self.thread = threading.Thread(target=self._update, daemon=True)
        self.thread.start()

    def _update(self):
        while self.running:
            ret, frame = self.cap.read()
            with self.lock:
                self.ret = ret
                self.frame = frame

    def read(self):
        with self.lock:
            return self.ret, self.frame.copy() if self.frame is not None else None

    def stop(self):
        self.running = False
        self.thread.join()
        self.cap.release()

def main():
    xmodel_path = sys.argv[1] if len(sys.argv) > 1 else "/work/yolov7_kv260.xmodel"
    camera_id = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    # Load model
    graph = xir.Graph.deserialize(xmodel_path)
    subgraphs = graph.get_root_subgraph().toposort_child_subgraph()
    dpu_subgraphs = [s for s in subgraphs if s.has_attr("device") and s.get_attr("device") == "DPU"]
    runner = vart.Runner.create_runner(dpu_subgraphs[0], "run")

    input_tensors = runner.get_input_tensors()
    output_tensors = runner.get_output_tensors()
    in_shape = input_tensors[0].dims
    in_h, in_w = in_shape[1], in_shape[2]
    print(f"Model input: {in_w}x{in_h}")

    # Open camera (threaded)
    cam = CameraThread(camera_id)
    if not cam.cap.isOpened():
        print(f"Error: cannot open camera {camera_id}")
        sys.exit(1)
    print("Camera opened. Press 'q' to quit.")

    cv2.namedWindow("YOLOv7", cv2.WINDOW_NORMAL)

    frame_start = time.time()

    while True:
        ret, frame = cam.read()
        if not ret or frame is None:
            continue

        # Preprocess
        img = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        img = cv2.resize(img, (in_w, in_h))
        img = img.astype(np.float32) / 255.0

        # Inference
        input_data = [np.expand_dims(img, axis=0)]
        output_data = [np.empty(ot.dims, dtype=np.float32) for ot in output_tensors]
        start = time.time()
        job_id = runner.execute_async(input_data, output_data)
        runner.wait(job_id)
        infer_ms = (time.time() - start) * 1000

        # Postprocess
        boxes = decode_outputs(output_data, img_size=in_w, conf_thresh=0.25)
        detections = nms(boxes, iou_thresh=0.45)

        # Draw
        frame_h, frame_w = frame.shape[:2]
        for det in detections:
            x1 = int(det[0] / in_w * frame_w)
            y1 = int(det[1] / in_h * frame_h)
            x2 = int(det[2] / in_w * frame_w)
            y2 = int(det[3] / in_h * frame_h)
            x1, y1 = max(0, x1), max(0, y1)
            x2, y2 = min(frame_w, x2), min(frame_h, y2)
            cls_id = int(det[5])
            label = COCO_CLASSES[cls_id] if cls_id < len(COCO_CLASSES) else str(cls_id)
            score = det[4]
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
            cv2.putText(frame, f"{label} {score:.2f}", (x1, y1-5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

        # FPS display
        total_ms = (time.time() - frame_start) * 1000
        fps = 1000.0 / total_ms if total_ms > 0 else 0
        fps_text = f"DPU:{infer_ms:.0f}ms Total:{total_ms:.0f}ms FPS:{fps:.1f} Det:{len(detections)}"
        cv2.putText(frame, fps_text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
        frame_start = time.time()

        cv2.imshow("YOLOv7", frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cam.stop()
    cv2.destroyAllWindows()
    print("Done.")

if __name__ == "__main__":
    main()
