"""Validation confusion matrix and local image review; never evaluates test."""
import argparse
import hashlib
import json
from pathlib import Path

import torch
from PIL import Image, ImageDraw
from torch.utils.data import DataLoader
from torchvision import datasets, transforms
from torchvision.transforms import functional as TF
from model import LeNet5


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path, required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.output_dir.exists():
        raise FileExistsError(args.output_dir)
    torch.set_num_threads(2)
    torch.manual_seed(42)
    ckpt = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    transform = transforms.Compose([transforms.Resize((32, 32)), transforms.ToTensor(),
                                    transforms.Normalize(ckpt['mean'], ckpt['std'])])
    val = datasets.ImageFolder(args.data_dir / 'val', transform=transform)
    if val.classes != ckpt['class_names']:
        raise ValueError('Class order differs from checkpoint')
    model = LeNet5(ckpt['input_channels'], len(val.classes))
    model.load_state_dict(ckpt['model_state'])
    model.eval()
    predictions = []
    with torch.inference_mode():
        for images, _ in DataLoader(val, batch_size=128, num_workers=0):
            predictions.extend(model(images).argmax(1).tolist())
    n = len(val.classes)
    confusion = torch.zeros((n, n), dtype=torch.int64)
    for (_, target), prediction in zip(val.samples, predictions):
        confusion[target, prediction] += 1
    support = confusion.sum(1)
    recall = confusion.diag().double() / support
    per_class = []
    for i, label in enumerate(val.classes):
        mistakes = sorted([(val.classes[j], int(confusion[i, j])) for j in range(n)
                           if j != i and confusion[i, j] > 0], key=lambda x: (-x[1], x[0]))
        per_class.append(dict(label=label, support=int(support[i]), correct=int(confusion[i,i]),
                              recall=float(recall[i]), predicted_count=int(confusion[:,i].sum()),
                              top_confusions=mistakes[:3]))
    report = dict(split='val', checkpoint_sha256=hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
                  class_names=val.classes, accuracy=float(confusion.diag().sum().double()/len(val)),
                  macro_recall=float(recall.mean()), confusion_matrix=confusion.tolist(), per_class=per_class)
    args.output_dir.mkdir(parents=True)
    (args.output_dir/'validation_metrics.json').write_text(json.dumps(report, indent=2)+'\n')
    sheet = Image.new('RGB', (900, 1000), 'white'); draw = ImageDraw.Draw(sheet)
    draw.text((8,5),'Validation: first error + midpoint example. Original | 32x32 enlarged',fill='black')
    selections = []
    for i, label in enumerate(val.classes):
        indices = [k for k, (_, target) in enumerate(val.samples) if target == i]
        error = next((k for k in indices if predictions[k] != i), indices[0])
        for col, k in enumerate((error, indices[len(indices)//2])):
            path, _ = val.samples[k]
            with Image.open(path) as source: original = source.convert('RGB')
            resized = TF.resize(original, [32,32])
            x, y = col*450, 30+i*96
            preview = original.copy(); preview.thumbnail((90,72))
            sheet.paste(preview, (x+5,y+18))
            sheet.paste(resized.resize((64,64),Image.Resampling.NEAREST),(x+100,y+18))
            draw.text((x+170,y+20),label,fill='black')
            draw.text((x+170,y+38),'pred: '+val.classes[predictions[k]],fill='black')
            draw.text((x+170,y+56),f'original: {original.width}x{original.height}',fill='black')
            selections.append(dict(path=str(Path(path).relative_to(args.data_dir)), prediction=val.classes[predictions[k]]))
    sheet.save(args.output_dir/'validation_examples.png')
    train = datasets.ImageFolder(args.data_dir/'train')
    crop_sheet = Image.new('RGB',(650,1030),'white'); draw=ImageDraw.Draw(crop_sheet)
    draw.text((5,5),'Training: resize | 4 random crops (seed 42); no color jitter',fill='black')
    cropper=transforms.RandomResizedCrop(32,scale=(0.8,1.0))
    crop_sources=[]
    for i,label in enumerate(train.classes):
        candidates=[p for p,t in train.samples if t==i]
        path=candidates[len(candidates)//2]
        with Image.open(path) as source: original=source.convert('RGB')
        y=30+i*100; draw.text((5,y),label,fill='black')
        images=[TF.resize(original,[32,32])]+[cropper(original) for _ in range(4)]
        for j,im in enumerate(images): crop_sheet.paste(im.resize((64,64),Image.Resampling.NEAREST),(160+j*92,y+12))
        crop_sources.append(str(Path(path).relative_to(args.data_dir)))
    crop_sheet.save(args.output_dir/'training_crop_examples.png')
    (args.output_dir/'review_samples.json').write_text(json.dumps(dict(validation=selections,train=crop_sources),indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='confusion_matrix'},indent=2))


if __name__ == '__main__':
    main()
