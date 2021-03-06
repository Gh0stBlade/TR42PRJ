﻿unit Unit2;

interface

uses
  unit3, // TTRProject type
  Vcl.Graphics, // TBitmap
  System.Generics.Collections; // TList<...>

type
  TFloorType = (Floor,door,tilt,roof,trigger,lava,climb,split1,split2,split3,split4,
                nocol1,nocol2,nocol3,nocol4,nocol5,nocol6,nocol7,nocol8,monkey,trigtrig,beetle);

type
  TParsedFloorData = record
    tipo : TFloorType;
    case TFloorType of
      Floor,trigger,lava,monkey,trigtrig,beetle:();
      door:(toRoom:UInt16);
      tilt,roof:(addX,addZ:int8);
      climb:(n,s,e,w:Boolean);
      split1,split2,split3,split4,nocol1,nocol2,nocol3,nocol4,
      nocol5,nocol6,nocol7,nocol8:(triH1,triH2:integer;corners:array[0..3] of UInt16);
  end;


type
  TSector = packed record
    FDindex,BoxIndex :UInt16;
    RoomBelow :UInt8;
    Floor :Int8;
    RoomAbove:UInt8;
    Ceiling:int8;
    floorInfo : TList<TParsedFloorData>;
    hasFD : Boolean;
  end;

type
  TVertex = packed record
    x,y,z : Int16;
end;

type
  TPortal = packed record
    toRoom : UInt16;
    normal : TVertex;
    vertices : array[0..3] of TVertex;
  end;

type
  TRoomColour = packed record
    b,g,r,a : UInt8;
  end;

type
  TRoom = record
    x,z,yBottom,yTop : Int32;
    numZ,numX : UInt16;
    Sectors:array of TSector;
    num_portals : UInt16;
    Portals:array of TPortal;
    colour : TRoomColour;
    altroom : Int16;
    flags:UInt16;
    waterscheme,reverb,altgroup:UInt8;
  end;


type
  TTRLevel = class
  private
    procedure parseFloorData(FDindex:UInt16;out list:TList<TParsedFloorData>);
  public
    bmp : TBitmap;
    file_version: uint32;
    num_room_textiles, num_obj_textiles, num_bump_textiles: uint16;
    num_sounds: uint32;
    num_rooms: uint16;
    num_animations, num_state_changes, num_anim_dispatches, num_anim_commands,
    num_meshtrees, size_keyframes, num_moveables, num_statics: uint32;
    num_floordata : UInt32;
    floordata : array of UInt16;
    rooms : array of TRoom;
    constructor Create;
    destructor Destroy;override;
    function Load(filename: string): uint8;
    function ConvertToPRJ(const filename:string): TTRProject;
  end;

implementation

uses
  System.SysUtils, Vcl.Dialogs,
  System.Classes, //TMemoryStream, TBinaryReader
  System.ZLib, // ZDecompressStream() - decompress TR4 data
  Imaging, ImagingTypes, ImagingComponents, // Vampyre Imaging Library for .TGA support
  System.Math; // MaxIntValue()

procedure TTRLevel.parseFloorData(FDindex:UInt16;out list:TList<TParsedFloorData>);

  procedure parseFloorType(arg:UInt16;out f,sub,e:uint16);
  begin
    f:=(arg and $001f);
    sub:=(arg and $7f00) shr 8;
    e:=(arg and $8000) shr 15;
  end;

var
  fd:TParsedFloorData;
  data : UInt16;
  f,sub,e :UInt16;
  k:integer;
begin
  if FDindex=0 then
  begin
    fd.tipo:=Floor;
    list.Add(fd);
    Exit;
  end;
  e := 0;
  k :=0;
  while (e=0) and (FDIndex+k < num_floordata) do
  begin
    data:= floordata[FDindex+k];
    Inc(k);
    parseFloorType(data,f,sub,e);
    fd.tipo:=TFloorType(f);
    if fd.tipo = door then
    begin
      fd.toRoom:=floordata[FDindex+k];
      Inc(k);
    end
    else if (fd.tipo = tilt) or (fd.tipo=roof) then
    begin
      fd.addX:= int8((floordata[FDindex+k] and $ff00) shr 8);
      fd.addZ:= int8(floordata[FDindex+k] and $00ff);
      Inc(k);
    end
    else if fd.tipo = trigger then
    begin
      repeat
        data := floordata[FDIndex+k];
        Inc(k);
      until ((data and $8000) = $8000);
    end
    else if fd.tipo = climb then
    begin
      if (sub and $0001) = $0001 then fd.e :=True else fd.e :=False;
      if (sub and $0002) = $0002 then fd.s :=True else fd.s :=False;
      if (sub and $0004) = $0004 then fd.w :=True else fd.w :=False;
      if (sub and $0008) = $0008 then fd.n :=True else fd.n :=False;
    end
    else if fd.tipo in [split1..nocol8] then
    begin
      fd.triH1 := (data and $03e0) shr 4;
      fd.triH2 := (data and $7c00) shr 8;
      data := floordata[FDindex+k];
      Inc(k);
      fd.corners[0]:=data and $000f;
      fd.corners[1]:=(data and $00f0) shr 4;
      fd.corners[2]:=(data and $0f00) shr 8;
      fd.corners[3]:=(data and $f000) shr 12;
    end;
    list.Add(fd);
  end;

end;


constructor TTRLevel.Create;
begin
  inherited;
  file_version := 0;
end;

destructor TTRLevel.Destroy;
var
  i,j : Integer;
begin
  bmp.Free;
  for i:=0 to High(rooms) do
  begin
    for j:=0 to High(rooms[i].Sectors) do
    begin
      if Assigned(rooms[i].Sectors[j].floorInfo) then
        rooms[i].Sectors[j].floorInfo.Free;
    end;
  end;
  inherited;
end;

function TTRLevel.Load(filename: string): uint8;
const
  spr = 'spr';
  tex = 'tex';
var
  version: uint32;
  resultado: uint8;
  f: file;
  memfile: TMemoryStream;
  br, br2,br3: TBinaryReader;
  size, size2, size3: uint32;
  geometry1: TMemoryStream;
  geometry: TMemoryStream;
  tex32 : TMemoryStream;
  i, j: integer;
  s: string;
  r:TRoom;
  b:TBitmap;
  col :TColor;
  rd,gr,bl,al:UInt8;
  success:Boolean;
  sectorFD:TList<TParsedFloorData>;
begin
  resultado := 0;
  if FileExists(filename) then
  begin
    FileMode := 0;
    assignfile(f, filename);
    Reset(f, 1);
    BlockRead(f, version, 4);
    CloseFile(f);
    if (version <> $00345254) and (version <> $63345254) then
    begin
      version := 0;
      resultado := 2;
    end;
  end
  else
  begin
    version := 0;
    resultado := 1;
  end;

  if version = $63345254 then
  begin
    resultado := 3;
    version := 0;
  end;

  if resultado <> 0 then
  begin
    Result := resultado;
    Exit;
  end;
  success:=False;
  memfile := TMemoryStream.Create;
  try
    memfile.LoadFromFile(filename);
    br := TBinaryReader.Create(memfile);
    try
      file_version := br.ReadUInt32;
      num_room_textiles := br.ReadUInt16;
      num_obj_textiles := br.ReadUInt16;
      num_bump_textiles := br.ReadUInt16;
      memfile.seek(4, soCurrent);
      size := br.ReadUInt32;
      geometry1 := TMemoryStream.Create;
      geometry1.CopyFrom(memfile,size);
      geometry1.Position:=0;
      tex32:=TMemoryStream.Create;
      ZDecompressStream(geometry1,tex32);
      tex32.Position:=0;
      geometry1.Free;
      if Assigned(bmp) then bmp.Free;
      b:=TBitmap.Create;
      b.PixelFormat:=pf24bit;
      b.Width:=256;
      b.Height:=num_room_textiles * 256; //tex32.Size div 256 div 4;
      br3:=TBinaryReader.Create(tex32);
      for i:=0 to b.Height-1 do
      begin
        for j := 0 to 255 do
        begin
          bl:=br3.ReadByte;
          gr:=br3.ReadByte;
          rd:=br3.ReadByte;
          al:=br3.ReadByte;
          if al=0 then
          begin
            bl:=255;
            rd:=255;
            gr:=0;
          end;
          col := 0;
          col := col or (bl shl 16);
          col := col or (gr shl 8);
          col := col or rd;
          b.Canvas.Pixels[j,i]:= col;
        end;
      end;
      br3.Free;
      bmp:=b;
      memfile.Seek(4, soCurrent);
      size := br.ReadUInt32;
      memfile.Seek(size, soCurrent); //skip the textiles16
      memfile.Seek(4, soCurrent);
      size := br.ReadUInt32;
      memfile.Seek(size, soCurrent); //skip the font and sky
      size2 := br.ReadUInt32;
      size := br.ReadUInt32;
      geometry1 := TMemoryStream.Create;
      geometry1.CopyFrom(memfile, size);
      geometry1.Position := 0;
      geometry := TMemoryStream.Create;
      ZDecompressStream(geometry1, geometry);
      geometry.Position := 0;
      geometry1.Free;
      num_sounds := br.ReadUInt32;
      br2 := TBinaryReader.Create(geometry);
      geometry.Seek(4, soCurrent);
      num_rooms := br2.ReadUInt16;

      SetLength(rooms,num_rooms);
      for i := 0 to High(rooms) do
      begin
        r.z := br2.ReadInt32;
        r.x := br2.ReadInt32;
        r.yBottom := br2.ReadInt32;
        r.yTop := br2.ReadInt32;
        size := br2.ReadUInt32; //num room mesh data words
        geometry.Seek(size * 2, soCurrent); //skip verts, quads, tris, sprites
        r.num_portals := br2.ReadUInt16; //num portals
        SetLength(r.Portals,r.num_portals);
        for j := 1 to r.num_portals do
        begin
          geometry.ReadBuffer(r.Portals[j-1],32);
        end;
        r.numX := br2.ReadUInt16;   // X is east west in RoomEdit - opposite of what TRosetta stone says!
        r.numZ := br2.ReadUInt16;   // Z is north south as per RoomEdit grid
        SetLength(r.Sectors, r.numX*r.numZ);
        for j := 1 to r.numX * r.numZ do
        begin
          geometry.ReadBuffer(r.Sectors[j-1],8); // X columns, Z rows
          r.Sectors[j-1].hasFD:=False;
        end;
        geometry.ReadBuffer(r.colour,4);
        size := br2.ReadUInt16; //num lights
        for j := 1 to size do
        begin
          geometry.Seek(46, soCurrent); //skip lights
        end;
        size := br2.ReadUInt16; //num static meshes
        for j := 1 to size do
        begin
          geometry.Seek(20, soCurrent); //skip static meshes
        end;
        r.altroom := br2.ReadInt16;
        r.flags := br2.ReadUInt16;
        r.waterscheme := br2.ReadByte;
        r.reverb := br2.ReadByte;
        r.altgroup := br2.ReadByte;
        rooms[i] := r;
      end;
      num_floordata := br2.ReadUInt32;
      SetLength(floordata,num_floordata);
      geometry.ReadBuffer(floordata[0],num_floordata*2);
      size := br2.ReadUInt32; //num object mesh data words
      geometry.Seek(size * 2, soCurrent); //skip object meshes
      size := br2.ReadUInt32; //num mesh pointers
      geometry.Seek(size * 4, soCurrent); //skip mesh pointers
      num_animations := br2.ReadUInt32;
      geometry.Seek(num_animations * 40, soCurrent);
      num_state_changes := br2.ReadUInt32;
      geometry.Seek(num_state_changes * 6, soCurrent);
      num_anim_dispatches := br2.ReadUInt32;
      geometry.Seek(num_anim_dispatches * 8, soCurrent);
      num_anim_commands := br2.ReadUInt32;
      geometry.Seek(num_anim_commands * 2, soCurrent);
      num_meshtrees := br2.ReadUInt32;
      geometry.Seek(num_meshtrees * 4, soCurrent);
      size_keyframes := br2.ReadUInt32;
      geometry.Seek(size_keyframes * 2, soCurrent);
      num_moveables := br2.ReadUInt32;
      geometry.Seek(num_moveables * 18, soCurrent);
      num_statics := br2.ReadUInt32;
      geometry.Seek(num_statics * 32, soCurrent);
      s := br2.ReadChar;
      s := s + br2.ReadChar;
      s := s + br2.ReadChar;
      s := LowerCase(s);
      if s <> spr then
        MessageDlg('SPR landmark not read correctly!',mtError,[mbOK],0);
      size := br2.ReadUInt32; // num sprite tex
      geometry.Seek(size * 16, soCurrent);  //skip sprite tex
      size := br2.ReadUInt32; // num sprite seq
      geometry.Seek(size * 8, soCurrent);  //skip sprite seq
      size := br2.ReadUInt32; // num cameras
      geometry.Seek(size * 16, soCurrent);  //skip cameras
      size := br2.ReadUInt32; // num flyby cams
      geometry.Seek(size * 40, soCurrent);  //skip flyby cams
      size := br2.ReadUInt32; // num sound sources
      geometry.Seek(size * 16, soCurrent);  //skip sound sources
      size2 := br2.ReadUInt32; // num Boxes
      geometry.Seek(size2 * 8, soCurrent);  //skip boxes
      size := br2.ReadUInt32; // num overlaps
      geometry.Seek(size * 2, soCurrent);  //skip overlaps
      geometry.Seek(size2 * 20, soCurrent);  //skip zones
      size := br2.ReadUInt32; // num anim tex words
      geometry.Seek(size * 2, soCurrent);  //skip anim tex words
      geometry.Seek(1,soCurrent); // skip uv ranges
      s := br2.ReadChar;
      s := s + br2.ReadChar;
      s := s + br2.ReadChar;
      s := LowerCase(s);
      if s <> tex then
        MessageDlg('TEX landmark not read correctly!',mtError,[mbOK],0);
      size := br2.ReadUInt32; // num textures
      geometry.Seek(size * 38, soCurrent);  //skip textures

      br2.Free;
      geometry.Free;
      success:=True;
    finally
      br.Free;
    end;
  finally
    memfile.Free;
  end;
  if success then
  begin
    for i:=0 to High(rooms) do
    begin
      for j:=0 to High(rooms[i].Sectors) do
      begin
        if rooms[i].Sectors[j].FDindex =0 then Continue;
        sectorFD := TList<TParsedFloorData>.Create;
        rooms[i].Sectors[j].hasFD:=True;
        parseFloorData(rooms[i].Sectors[j].FDindex,sectorFD);
        rooms[i].Sectors[j].floorInfo:=sectorFD;
      end;
    end;
  end;

end;

function TTRLevel.ConvertToPRJ(const filename :string): TTRProject;
var
  p:TTRProject;
  slots:uint32;
  i,j,k,ii,jj:Integer;
  r1:TRoom;
  sector:TSector;
  s:string;
  img:TImageData;
  b:Integer;
  fd:TParsedFloorData;
  maxCorner:Word;
  a:array[0..3]of integer;
  po:TPortal;
  isHorizontalDoor : Boolean;
begin
  if (num_rooms <= 100) then slots:=100
  else if ((num_rooms>100) and (num_rooms<=200)) then slots:=200
  else slots := 300;
  p := TTRProject.Create(num_rooms,slots);

  s := ChangeFileExt(filename,'.tga');
  InitImage(img);
  img.Format := ifR8G8B8;
  ConvertBitmapToData(bmp,img); // make sure bitmap's pixelformat was set to 24!!
  SaveImageToFile(s,img);
  FreeImage(img);

  p.TGAFilePath := ExtractShortPathName(s);
  if LowerCase(p.TGAFilePath)='.tga' then MessageDlg('PRJ TGA filename error',mtError,[mbOK],0);
  p.TGAFilePath := p.TGAFilePath+' ';  // don't forget space
  for i:=0 to High(rooms) do
  begin
    r1:=rooms[i];
    p.Rooms[i].x := r1.x;
//    p.Rooms[i].y := r1.yBottom;
    p.Rooms[i].z := r1.z;
    p.Rooms[i].xsize := r1.numX;
    p.Rooms[i].zsize := r1.numZ;
    p.Rooms[i].xoffset := (20 - r1.numX) div 2;
    p.Rooms[i].zoffset := (20 - r1.numZ) div 2;
    p.Rooms[i].xpos := r1.x div 1024;
    p.Rooms[i].zpos := r1.z  div 1024;
    p.Rooms[i].ambient.r := r1.colour.r;
    p.Rooms[i].ambient.g := r1.colour.g;
    p.Rooms[i].ambient.b := r1.colour.b;
    p.Rooms[i].ambient.a := r1.colour.a;
    p.Rooms[i].fliproom := r1.altroom;
    p.rooms[i].flags1 := r1.flags; // TODO: check they're the same
    SetLength(p.Rooms[i].blocks,r1.numZ*r1.numX);
    for j:=0 to r1.numZ-1 do  // rows
    begin
      for k:=0 to r1.numX-1 do  // columns
      begin
        b := j*r1.numX+k; // index to block array and sector array
        sector := r1.Sectors[b];
        p.Rooms[i].blocks[b].id := $1; // default is floor type
        p.Rooms[i].blocks[b].Floor := -sector.Floor;
        p.Rooms[i].blocks[b].ceiling := -sector.Ceiling;

        // corner grey blocks can be any heights I guess since never seen
        // aktrekker makes them same as corner blocks of inner blocks
        // floor and ceil heights for grey blocks/walls are division lines
        if ((k=0)and(j=0)) or ((k=r1.numX-1)and(j=0)) or ((k=0)and(j=r1.numZ-1)) or ((k=r1.numX-1)and(j=r1.numZ-1)) then
        begin
          p.Rooms[i].blocks[b].id := $1e;
          p.Rooms[i].blocks[b].Floor := 0;
          p.Rooms[i].blocks[b].ceiling := 20;
        end
        // other grey outer blocks
        else if (j=0) or (j=r1.numZ-1) or (k=0) or (k=r1.numX-1) then
        begin
          p.Rooms[i].blocks[b].id := $1e;
          p.Rooms[i].blocks[b].Floor := -r1.yBottom div 256;
          p.Rooms[i].blocks[b].ceiling := -r1.yTop div 256;
        end
        // green wall blocks except those with door FloorData
        else if (sector.Floor = -127) then
        begin
          p.Rooms[i].blocks[b].id := $e;
          p.Rooms[i].blocks[b].Floor := -r1.yBottom div 256;
          p.Rooms[i].blocks[b].ceiling := -r1.yTop div 256;
        end
        // black door blocks - no good without door arrays implemented
        else if (sector.RoomBelow<>255) and (sector.RoomAbove<>255) then
        begin
//          p.Rooms[i].blocks[b].id := $7;
        end
        else if (sector.RoomBelow<>255) then
        begin
//          p.Rooms[i].blocks[b].id := $3;
        end
        else if (sector.RoomAbove<>255) then
        begin
//          p.Rooms[i].blocks[b].id := $5;
        end;

        if sector.hasFD then // need to check since no list of floordata for FDindex=0 sectors
        begin
          for ii :=0 to sector.floorInfo.Count-1 do
          begin
            fd:=sector.floorInfo[ii];
            if fd.tipo in [trigger] then Continue; // not implemented
            if fd.tipo = door then  // not implemented
            begin
              isHorizontalDoor:=True;
              for jj := 0 to High(r1.Portals) do
              begin
                po:=r1.Portals[jj];
                // check if door toRoom is above by checking portals
                // if it's not a vertical door then it is a horizontal one
                if po.normal.y = 0 then // check vertical portals
                begin
                  if po.toRoom = fd.toRoom then
                  begin
                    isHorizontalDoor := False;
                    Break;
                  end;
                end;
              end;
              if isHorizontalDoor then // it's a green wall block not a floor block
              begin
                if p.Rooms[i].blocks[b].id = $1 then p.Rooms[i].blocks[b].id := $e;
                if p.Rooms[i].blocks[b].id = $1e then
                begin
                  p.Rooms[i].blocks[b].Floor := -sector.Floor;
                  p.Rooms[i].blocks[b].ceiling := -sector.Ceiling;
                end;
              end;
//              if p.Rooms[i].blocks[b].id = $1e then p.Rooms[i].blocks[b].id := $6
              Continue;
            end;
            if fd.tipo=beetle then
            begin
              p.Rooms[i].blocks[b].flags2:= p.Rooms[i].blocks[b].flags2 or $0040;
              Continue;
            end;
            if fd.tipo=trigtrig then
            begin
              p.Rooms[i].blocks[b].flags2:= p.Rooms[i].blocks[b].flags2 or $0020;
              Continue;
            end;
            if fd.tipo=climb then
            begin
              if fd.n then p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $0200;
              if fd.s then p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $0080;
              if fd.w then p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $0100;
              if fd.e then p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $0040;
              Continue;
            end;
            if fd.tipo=monkey then
            begin
              p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $4000;
              Continue;
            end;
            if fd.tipo=lava then
            begin
              p.Rooms[i].blocks[b].flags1:=p.Rooms[i].blocks[b].flags1 or $0010;
              Continue;
            end;
            if fd.tipo=tilt then
            begin // can have both X and Z tilt
              if fd.addX>=0 then
              begin
                p.Rooms[i].blocks[b].floorcorner[2]:=fd.addX;
                p.Rooms[i].blocks[b].floorcorner[3]:=fd.addX;
              end
              else
              begin
                p.Rooms[i].blocks[b].floorcorner[0]:= -fd.addX;
                p.Rooms[i].blocks[b].floorcorner[1]:= -fd.addX;
              end;
              if fd.addZ>=0 then
              begin
                p.Rooms[i].blocks[b].floorcorner[0]:=p.Rooms[i].blocks[b].floorcorner[0]+fd.addZ;
                p.Rooms[i].blocks[b].floorcorner[3]:=p.Rooms[i].blocks[b].floorcorner[3]+fd.addZ;
              end
              else
              begin
                p.Rooms[i].blocks[b].floorcorner[2]:=p.Rooms[i].blocks[b].floorcorner[2]+Abs(fd.addZ);
                p.Rooms[i].blocks[b].floorcorner[1]:=p.Rooms[i].blocks[b].floorcorner[1]+Abs(fd.addZ);
              end;
              p.Rooms[i].blocks[b].Floor := p.Rooms[i].blocks[b].Floor-(Abs(fd.addX)+abs(fd.addZ));
              Continue;
            end; // tilt
            if fd.tipo=roof then
            begin // can have both X and Z roof
              if fd.addX>=0 then
              begin
                p.Rooms[i].blocks[b].ceilcorner[0]:=-fd.addX;
                p.Rooms[i].blocks[b].ceilcorner[1]:=-fd.addX;
              end
              else
              begin
                p.Rooms[i].blocks[b].ceilcorner[2]:=fd.addX;
                p.Rooms[i].blocks[b].ceilcorner[3]:=fd.addX;
              end;
              if fd.addZ>=0 then
              begin
                p.Rooms[i].blocks[b].ceilcorner[1]:=p.Rooms[i].blocks[b].ceilcorner[1]-fd.addZ;
                p.Rooms[i].blocks[b].ceilcorner[2]:=p.Rooms[i].blocks[b].ceilcorner[2]-fd.addZ;
              end
              else
              begin
                p.Rooms[i].blocks[b].ceilcorner[0]:=p.Rooms[i].blocks[b].ceilcorner[0]+fd.addZ;
                p.Rooms[i].blocks[b].ceilcorner[3]:=p.Rooms[i].blocks[b].ceilcorner[3]+fd.addZ;
              end;
              p.Rooms[i].blocks[b].Ceiling := p.Rooms[i].blocks[b].ceiling+Abs(fd.addX)+abs(fd.addZ);
              Continue;
            end; // roof
            if fd.tipo in [split1,split2,nocol1..nocol4] then  // floor splits
            begin
              // no good for corner heights > 15!!!  maybe need to check geometry vertices
              p.Rooms[i].blocks[b].floorcorner[0]:=fd.corners[0];
              p.Rooms[i].blocks[b].floorcorner[1]:=fd.corners[1];
              p.Rooms[i].blocks[b].floorcorner[2]:=fd.corners[2];
              p.Rooms[i].blocks[b].floorcorner[3]:=fd.corners[3];
              a[0]:=fd.corners[0];
              a[1]:=fd.corners[1];
              a[2]:=fd.corners[2];
              a[3]:=fd.corners[3];
              maxCorner:=maxIntvalue(a);
              p.Rooms[i].blocks[b].Floor := p.Rooms[i].blocks[b].Floor-maxCorner;
              Continue;
            end; //floor splits
            if fd.tipo in [split3,split4,nocol5..nocol8] then // ceiling splits
            begin
              // no good for corner heights > 15!!!  maybe need to check geometry vertices
              p.Rooms[i].blocks[b].ceilcorner[0]:=-fd.corners[0];
              p.Rooms[i].blocks[b].ceilcorner[1]:=-fd.corners[1];
              p.Rooms[i].blocks[b].ceilcorner[2]:=-fd.corners[2];
              p.Rooms[i].blocks[b].ceilcorner[3]:=-fd.corners[3];
              a[0]:=fd.corners[0];
              a[1]:=fd.corners[1];
              a[2]:=fd.corners[2];
              a[3]:=fd.corners[3];
              maxCorner:=maxIntvalue(a);
              p.Rooms[i].blocks[b].ceiling := p.Rooms[i].blocks[b].ceiling+maxCorner;
              Continue;
            end; // ceiling splits
          end; // loop thru FData
        end; // has FData
      end; // loop thru X block columns
    end; // loop thru Z block rows
  end; // loop thru rooms
  Result := p;
end;

end.

