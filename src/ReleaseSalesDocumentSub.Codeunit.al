codeunit 50400 "ReleaseSalesDocumentSub"
{
    local procedure MarkSalesLinesForItemTracking(SalesHeader: Record "Sales Header"; var SalesLine: Record "Sales Line")
    begin
        SalesLine.SetRange("Document Type", SalesHeader."Document Type");
        SalesLine.SetRange("Document No.", SalesHeader."No.");
        SalesLine.SetRange(Type, SalesLine.Type::Item);
        SalesLine.SetFilter("No.", '<>%1', '');
        SalesLine.SetFilter("Outstanding Quantity", '>0');
        if SalesLine.FindSet() then
            repeat
                MarkSalesLineForTracking(SalesLine);
            until SalesLine.Next() = 0;
        SalesLine.MarkedOnly(true);
    end;

    local procedure MarkSalesLineForTracking(var SalesLine: Record "Sales Line")
    var
        Item: Record Item;
    begin
        if SalesLine.ReservEntryExist() then
            exit;

        Item := SalesLine.GetItem();

        case false of
            Item.IsInventoriableType(),
            Item.ItemTrackingCodeUseExpirationDates():
                exit;
        end;

        SalesLine.Mark(true);
    end;

    local procedure AssignItemTrackingToSalesLines(var SalesLine: Record "Sales Line"; CreateReservation: Boolean)
    begin
        if SalesLine.FindSet() then
            repeat
                AssignItemTrackingToSalesLine(SalesLine, CreateReservation);
            until SalesLine.Next() = 0;
    end;

    local procedure AssignItemTrackingToSalesLine(SalesLine: Record "Sales Line"; CreateReservation: Boolean)
    var
        ItemLedgerEntry: Record "Item Ledger Entry";
        Item: Record Item;
        CreateReservEntry: Codeunit "Create Reserv. Entry";
        RemainQtyToAssign: Decimal;
    begin
        Item := SalesLine.GetItem();
        Item.SetRange("Variant Filter", SalesLine."Variant Code");
        Item.SetRange("Location Filter", SalesLine."Location Code");

        if not ItemLedgerEntry.FindLinesWithItemToPlan(Item, false) then
            exit;

        RemainQtyToAssign := SalesLine."Outstanding Quantity";
        ItemLedgerEntry.SetCurrentKey("Expiration Date");
        ItemLedgerEntry.FindSet();
        repeat
            RemainQtyToAssign -= CreateReservationEntry(SalesLine, ItemLedgerEntry, RemainQtyToAssign, CreateReservation);
        until (ItemLedgerEntry.Next() = 0) or (RemainQtyToAssign = 0);
    end;

    local procedure CreateReservationEntry(SalesLine: Record "Sales Line"; ItemLedgerEntry: Record "Item Ledger Entry"; RemainQtyToAssign: Decimal; CreateReservation: Boolean): Decimal
    var
        TempReservationEntry: Record "Reservation Entry" temporary;
        TempTrackingSpecification: Record "Tracking Specification" temporary;
        Math: Codeunit Math;
        UnitofMeasureManagement: Codeunit "Unit of Measure Management";
        CreateReservEntry: Codeunit "Create Reserv. Entry";
        QtyToAssign: Decimal;
        QtyToAssignBase: Decimal;
    begin
        QtyToAssign := Math.Min(ItemLedgerEntry."Remaining Quantity", RemainQtyToAssign);
        QtyToAssignBase := UnitofMeasureManagement.CalcBaseQty(QtyToAssign, SalesLine."Qty. per Unit of Measure");

        TempReservationEntry."Lot No." := ItemLedgerEntry."Lot No.";
        TempReservationEntry."Serial No." := ItemLedgerEntry."Serial No.";

        CreateReservEntry.CreateReservEntryFor(Database::"Sales Line", SalesLine."Document Type".AsInteger(), SalesLine."Document No.", '', 0,
            SalesLine."Line No.", SalesLine."Qty. per Unit of Measure", QtyToAssign, QtyToAssignBase, TempReservationEntry);

        if CreateReservation then begin
            TempTrackingSpecification.InitTrackingSpecification(Database::"Item Ledger Entry", 0, '', '', 0, ItemLedgerEntry."Entry No.",
                ItemLedgerEntry."Variant Code", ItemLedgerEntry."Location Code", ItemLedgerEntry."Qty. per Unit of Measure");
            TempTrackingSpecification.CopyTrackingFromItemLedgEntry(ItemLedgerEntry);
            CreateReservEntry.CreateReservEntryFrom(TempTrackingSpecification);

            CreateReservEntry.CreateEntry(SalesLine."No.", SalesLine."Variant Code", SalesLine."Location Code", SalesLine.Description, 0D,
                SalesLine."Shipment Date", 0, Enum::"Reservation Status"::Reservation);
        end else begin
            CreateReservEntry.CreateEntry(SalesLine."No.", SalesLine."Variant Code", SalesLine."Location Code", SalesLine.Description, 0D,
                SalesLine."Shipment Date", 0, Enum::"Reservation Status"::Surplus);
        end;
        exit(QtyToAssign);
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Release Sales Document", 'OnBeforeModifySalesDoc', '', false, false)]
    local procedure OnBeforeModifySalesDoc(var SalesHeader: Record "Sales Header"; PreviewMode: Boolean; var IsHandled: Boolean);
    var
        ConfirmManagement: Codeunit "Confirm Management";
        SalesLine: Record "Sales Line";
        CreateReservation: Boolean;
    begin
        case true of
            PreviewMode,
            IsHandled,
            SalesHeader."Document Type" <> SalesHeader."Document Type"::Order:
                exit;
        end;

        MarkSalesLinesForItemTracking(SalesHeader, SalesLine);
        if SalesLine.IsEmpty then
            exit;

        CreateReservation := ConfirmManagement.GetResponseOrDefault('Item Tracking will be created, do you want to reserve too?', false);
        AssignItemTrackingToSalesLines(SalesLine, CreateReservation);
    end;

}